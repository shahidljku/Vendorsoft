import { Env } from '../types';
import { getDocument, commitAtomicWrites, deleteDocument, logAuditEvent } from './firestore';

export class LockService {
  /**
   * Acquires a distributed lock, executes the callback, and safely releases the lock.
   * Enforces strict ownership validation on release.
   */
  static async withLock<T>(
    env: Env,
    lockPrefix: string,
    resourceId: string,
    ttlMs: number,
    context: { requestId?: string; customerId?: string; subscriptionId?: string; paymentId?: string; transferId?: string },
    callback: () => Promise<T>
  ): Promise<T> {
    const lockId = `${lockPrefix}_${resourceId}`;
    const now = Date.now();
    const lockToken = crypto.randomUUID();
    const requestId = context.requestId || crypto.randomUUID();

    // 1. Check for orphaned lock
    const existingLock = await getDocument(env, 'idempotency_keys', lockId);
    if (existingLock) {
      if (existingLock.expiresAtEpochMs > now) {
        await logAuditEvent(env, 'LOCK_COLLISION', {
          ...context,
          lockId,
          requestId,
          existingLockToken: existingLock.lockToken,
          expiresAtEpochMs: existingLock.expiresAtEpochMs
        });
        const err: any = new Error('Resource is currently locked by another process.');
        err.code = 'ALREADY_EXISTS';
        throw err;
      } else {
        // Self-heal: Orphaned lock
        await logAuditEvent(env, 'LOCK_EXPIRED', {
          ...context,
          lockId,
          requestId,
          existingLockToken: existingLock.lockToken,
          message: 'Deleted orphaned lock before acquisition'
        });
        await deleteDocument(env, 'idempotency_keys', lockId);
      }
    }

    // 2. Acquire lock with ownership token
    try {
      await commitAtomicWrites(env, [{
        collectionPath: 'idempotency_keys',
        documentId: lockId,
        data: { 
          keyId: lockId, 
          expiresAtEpochMs: now + ttlMs, 
          responsePayload: 'LOCKED',
          lockToken,
          requestId,
          ownerId: context.customerId || 'system'
        },
        requireDoesNotExist: true
      }]);
      
      await logAuditEvent(env, 'LOCK_ACQUIRED', {
        ...context,
        lockId,
        requestId,
        lockToken,
        ttlMs
      });
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        await logAuditEvent(env, 'LOCK_COLLISION', {
          ...context,
          lockId,
          requestId,
          message: 'Collision during atomic acquisition'
        });
        const lockErr: any = new Error('Resource is currently locked by another process.');
        lockErr.code = 'ALREADY_EXISTS';
        throw lockErr;
      }
      throw err;
    }

    // 3. Execute critical section
    try {
      return await callback();
    } finally {
      // 4. Safe Release (Verify Ownership)
      try {
        const lockVerify = await getDocument(env, 'idempotency_keys', lockId);
        if (lockVerify && lockVerify.lockToken === lockToken) {
          await deleteDocument(env, 'idempotency_keys', lockId);
          await logAuditEvent(env, 'LOCK_RELEASED', {
            ...context,
            lockId,
            requestId,
            lockToken
          });
        } else if (lockVerify) {
           await logAuditEvent(env, 'LOCK_RELEASE_STOLEN', {
             ...context,
             lockId,
             requestId,
             expectedToken: lockToken,
             actualToken: lockVerify.lockToken,
             message: 'Lock was acquired by someone else before release.'
           });
        } else {
           await logAuditEvent(env, 'LOCK_RELEASE_NOT_FOUND', {
             ...context,
             lockId,
             requestId,
             lockToken,
             message: 'Lock expired or was deleted before release.'
           });
        }
      } catch (cleanupErr) {
        console.error(`Failed to safely release lock ${lockId}:`, cleanupErr);
      }
    }
  }
}
