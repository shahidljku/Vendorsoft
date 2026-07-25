import { Env } from '../types';
import { RequestContext } from './logger';
import { getDocument, commitAtomicWrites, queryCollection } from './firestore';
import { generateShortId } from '../cryptoEngine';

export type IdempotencyState = 'NONE' | 'INITIATING' | 'ORDER_CREATED' | 'FAILED';

export class IdempotencyFSM {
  static transition(current: IdempotencyState, target: IdempotencyState): IdempotencyState {
    const validTransitions: Record<IdempotencyState, IdempotencyState[]> = {
      'NONE': ['INITIATING'],
      'INITIATING': ['ORDER_CREATED', 'FAILED'],
      'ORDER_CREATED': ['ORDER_CREATED'], // Idempotency no-op
      'FAILED': ['INITIATING'] // Recovery retry
    };

    if (!validTransitions[current]?.includes(target)) {
      const err: any = new Error(`Illegal idempotency transition from '${current}' to '${target}'`);
      err.code = 'ILLEGAL_TRANSITION';
      throw err;
    }
    return target;
  }
}

export class IdempotencyService {
  /**
   * Executes a state-mutating saga (such as order creation) with crash-resilient idempotency,
   * explicit ownerToken lease semantics, and gateway crash recovery.
   */
  static async executeOrderSaga<T>(
    ctx: RequestContext,
    env: Env,
    keyId: string | undefined,
    now: number,
    action: (ownerToken: string) => Promise<T>
  ): Promise<T> {
    if (!keyId) {
      // If no idempotency key is provided, generate an ephemeral ownerToken and execute directly
      return await action(generateShortId());
    }

    const myOwnerToken = generateShortId();
    const leaseDurationMs = 15000;

    // Step 1: Attempt to acquire fresh saga lease
    const initialRecord = {
      keyId,
      status: IdempotencyFSM.transition('NONE', 'INITIATING'),
      ownerToken: myOwnerToken,
      ownerLeaseExpiresAtEpochMs: now + leaseDurationMs,
      createdAtEpochMs: now,
      updatedAtEpochMs: now
    };

    try {
      await commitAtomicWrites(ctx, env, [{
        collectionPath: 'idempotency_keys',
        documentId: keyId,
        data: initialRecord,
        requireDoesNotExist: true
      }]);
    } catch (err: any) {
      if (err.code !== 'ALREADY_EXISTS') {
        throw err;
      }

      // Record already exists, inspect state
      const existingDoc = await getDocument(ctx, env, 'idempotency_keys', keyId);
      if (!existingDoc) {
        // Rare race condition where document was deleted between commit and get
        return await this.executeOrderSaga(ctx, env, keyId, now, action);
      }

      if (existingDoc.status === 'ORDER_CREATED') {
        // Idempotent no-op transition
        IdempotencyFSM.transition('ORDER_CREATED', 'ORDER_CREATED');
        if (!existingDoc.responsePayload) {
          throw new Error('Idempotent order found but payload is empty.');
        }
        return JSON.parse(existingDoc.responsePayload) as T;
      }

      if (existingDoc.status === 'INITIATING') {
        if (now < existingDoc.ownerLeaseExpiresAtEpochMs) {
          // Another worker is actively initiating this order
          const inProgressErr: any = new Error('ORDER_IN_PROGRESS: Please wait while your order is being initiated.');
          inProgressErr.code = 'ORDER_IN_PROGRESS';
          throw inProgressErr;
        }

        // LEASE EXPIRED: Worker Crash Recovery
        // Before creating a new Razorpay order, check if previous worker succeeded at gateway
        // by querying canonical payments ledger where idempotencyKey matches.
        const matchingPayments = await queryCollection(ctx, env, 'payments', [
          { field: 'idempotencyKey', op: 'EQUAL', value: keyId }
        ]);

        if (matchingPayments && matchingPayments.length > 0) {
          const recoveredPayment = matchingPayments[0];
          const recoveredData = {
            razorpayOrderId: recoveredPayment.razorpayOrderId,
            amountPaise: recoveredPayment.amountPaise || (recoveredPayment.amountInr * 100),
            keyId: env.RAZORPAY_KEY_ID || ''
          } as unknown as T;

          // Transition to ORDER_CREATED directly from recovered canonical state
          const finalizedRecord = {
            ...existingDoc,
            status: IdempotencyFSM.transition('INITIATING', 'ORDER_CREATED'),
            ownerToken: myOwnerToken,
            responsePayload: JSON.stringify(recoveredData),
            updatedAtEpochMs: now
          };

          await commitAtomicWrites(ctx, env, [{
            collectionPath: 'idempotency_keys',
            documentId: keyId,
            data: finalizedRecord
          }]);

          return recoveredData;
        }

        // Previous worker crashed before/during gateway call without writing payment ledger.
        // Perform atomic lease takeover in Firestore.
        const takeoverRecord = {
          ...existingDoc,
          ownerToken: myOwnerToken,
          ownerLeaseExpiresAtEpochMs: now + leaseDurationMs,
          updatedAtEpochMs: now
        };

        await commitAtomicWrites(ctx, env, [{
          collectionPath: 'idempotency_keys',
          documentId: keyId,
          data: takeoverRecord
        }]);

        // Proceed to Step 2 with our new lease
      } else if (existingDoc.status === 'FAILED') {
        // Recovery retry from failed state
        const retryRecord = {
          ...existingDoc,
          status: IdempotencyFSM.transition('FAILED', 'INITIATING'),
          ownerToken: myOwnerToken,
          ownerLeaseExpiresAtEpochMs: now + leaseDurationMs,
          updatedAtEpochMs: now
        };

        await commitAtomicWrites(ctx, env, [{
          collectionPath: 'idempotency_keys',
          documentId: keyId,
          data: retryRecord
        }]);
      } else {
        throw new Error(`Unknown idempotency status: ${existingDoc.status}`);
      }
    }

    // Step 2: Execute gateway action outside locks while holding active lease
    let resultData: T;
    try {
      resultData = await action(myOwnerToken);
    } catch (actionErr: any) {
      // Transition to FAILED if we still own the lease
      const latestDoc = await getDocument(ctx, env, 'idempotency_keys', keyId);
      if (latestDoc && latestDoc.ownerToken === myOwnerToken && latestDoc.status === 'INITIATING') {
        const failedRecord = {
          ...latestDoc,
          status: IdempotencyFSM.transition('INITIATING', 'FAILED'),
          errorMessage: actionErr.message || 'Gateway action failed',
          updatedAtEpochMs: Date.now()
        };
        await commitAtomicWrites(ctx, env, [{
          collectionPath: 'idempotency_keys',
          documentId: keyId,
          data: failedRecord
        }]).catch(() => {}); // Best effort failure recording
      }
      throw actionErr;
    }

    // Step 3: Finalize Saga (ORDER_CREATED) conditional on matching ownerToken and INITIATING status
    const currentDoc = await getDocument(ctx, env, 'idempotency_keys', keyId);
    if (!currentDoc || currentDoc.ownerToken !== myOwnerToken || currentDoc.status !== 'INITIATING') {
      const supersededErr: any = new Error('Saga lease superseded or invalidated during gateway call.');
      supersededErr.code = 'LEASE_SUPERSEDED';
      throw supersededErr;
    }

    const finalizedRecord = {
      ...currentDoc,
      status: IdempotencyFSM.transition('INITIATING', 'ORDER_CREATED'),
      responsePayload: JSON.stringify(resultData),
      updatedAtEpochMs: Date.now()
    };

    await commitAtomicWrites(ctx, env, [{
      collectionPath: 'idempotency_keys',
      documentId: keyId,
      data: finalizedRecord
    }]);

    return resultData;
  }
}
