import { Env, ApiResponse } from '../types';
import { authenticateRequest, createErrorResponse } from '../authGuard';
import { getDocument, setDocument, commitAtomicWrites, queryCollection, deleteDocument } from '../services/firestore';
import { generateShortId, generateSignedLeaseToken } from '../cryptoEngine';
import { executeRefundSaga } from '../webhooks';
import { LockService } from '../services/lock';
import { findSubscription, DiscoveryStrategy } from '../services/discovery';

/**
 * Handles POST /api/v1/orders/create
 * Initiates a new Razorpay payment order for subscription upgrade/renewal.
 */
export async function handleCreateOrder(request: Request, env: Env): Promise<Response> {
  // 1. Authenticate request and verify zero-trust identity headers
  const authResult = await authenticateRequest(request, env);
  if (authResult.errorResponse) return authResult.errorResponse;
  const identity = authResult.identity!;

  let customerId = identity.customerId;
  const installationId = identity.installationId || identity.installationUuid;

  if (!installationId) {
    return createErrorResponse(400, 'MISSING_INSTALLATION_ID', 'Missing installation UUID.');
  }

  // Look up customerId from installation if not passed in header
  if (!customerId) {
    const instDoc = await getDocument(env, 'installations', installationId);
    if (instDoc && instDoc.customerId) {
      customerId = instDoc.customerId;
    }
  }

  if (!customerId) {
    return createErrorResponse(400, 'MISSING_CUSTOMER_ID', 'Unable to determine customer ID. Please register first.');
  }

  // 2. Check global system configurations (`system_configs/global`)
  const sysConfig = await getDocument(env, 'system_configs', 'global');
  if (sysConfig) {
    if (sysConfig.maintenanceMode === true) {
      return createErrorResponse(503, 'MAINTENANCE_MODE', sysConfig.maintenanceMessage || 'System maintenance in progress.');
    }
    if (sysConfig.allowPayments === false) {
      return createErrorResponse(403, 'PAYMENTS_DISABLED', 'Online payments are currently disabled by system administrators.');
    }
  }

  // 3. Verify installation is not banned or revoked
  const instDoc = await getDocument(env, 'installations', installationId);
  if (instDoc) {
    if (instDoc.isBanned === true) {
      return createErrorResponse(403, 'INSTALLATION_BANNED', 'This hardware installation has been banned.');
    }
    if (instDoc.status === 'REVOKED') {
      return createErrorResponse(403, 'INSTALLATION_REVOKED', 'This installation has been revoked. Please request a device transfer.');
    }
  }

  // Pillar 6: Payment Gateway Transfer Bypass Patch (Pay-to-Steal Exploit)
  // We strictly block payment attempts from unauthorized devices if the subscription is currently ACTIVE.
  // If the subscription is EXPIRED, we allow payment to support Pillar 1 (Expired Account Mobility).
  const subs = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
  const activeSub = subs.find((s: any) => s.status === 'ACTIVE' && s.expiresAtEpochMs > Date.now());
  if (activeSub && activeSub.activeInstallationId && activeSub.activeInstallationId !== installationId) {
    return createErrorResponse(403, 'TRANSFER_REQUIRED', 'You must transfer the active account to this device before you can purchase a subscription.');
  }

  const trials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
  const activeTrial = trials.find((t: any) => t.status !== 'CANCELLED' && t.expiresAtEpochMs > Date.now());
  if (activeTrial && activeTrial.hardwareId !== installationId && activeTrial.hardwareId !== identity.hardwareId) {
    return createErrorResponse(403, 'TRANSFER_REQUIRED', 'You must transfer your active trial to this device before you can purchase a subscription.');
  }

  // 4. Parse payload
  let body: { planId?: string };
  try {
    body = await request.json();
  } catch {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be valid JSON.');
  }

  const rawPlanId = typeof body.planId === 'string' ? body.planId : '';
  if (rawPlanId.length > 50) {
    return createErrorResponse(400, 'INVALID_PLAN_ID', 'planId exceeds maximum allowed length.');
  }
  const planId = rawPlanId.trim().toUpperCase();
  if (!planId) {
    return createErrorResponse(400, 'MISSING_PLAN_ID', 'planId is required (e.g. PRO_MONTHLY or PRO_YEARLY).');
  }

  // 5. Look up plan pricing (`plans/{planId}`) or fall back to standard defaults if not in Firestore yet
  let priceInr = 1499; // Default yearly
  let durationDays = 365;
  let planName = 'Pro Annual License';

  const planDoc = await getDocument(env, 'plans', planId);
  if (planDoc) {
    if (planDoc.isActive === false) {
      return createErrorResponse(400, 'PLAN_INACTIVE', `Plan '${planId}' is no longer available for purchase.`);
    }
    priceInr = typeof planDoc.priceInr === 'number' ? planDoc.priceInr : priceInr;
    durationDays = typeof planDoc.durationDays === 'number' ? planDoc.durationDays : durationDays;
    planName = typeof planDoc.name === 'string' ? planDoc.name : planName;
  } else {
    if (planId === 'PRO_MONTHLY') {
      priceInr = 149;
      durationDays = 30;
      planName = 'Pro Monthly License';
    } else if (planId === 'PRO_YEARLY') {
      priceInr = 1499;
      durationDays = 365;
      planName = 'Pro Annual License';
    } else if (planId !== 'DEMO_FREE') {
      return createErrorResponse(400, 'INVALID_PLAN_ID', `Unsupported planId: ${planId}`);
    }
  }

  const amountInr = priceInr;
  const amountPaise = priceInr * 100;
  const now = Date.now();
  let razorpayOrderId = `order_${generateShortId()}`;

  // 6. Call Razorpay API (`POST https://api.razorpay.com/v1/orders`) if live credentials are configured
  if (env.RAZORPAY_KEY_ID && env.RAZORPAY_KEY_SECRET) {
    try {
      const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
      const rzpResp = await fetch('https://api.razorpay.com/v1/orders', {
        method: 'POST',
        headers: {
          'Authorization': authHeader,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          amount: amountPaise,
          currency: 'INR',
          receipt: `rcpt_${generateShortId()}`,
          notes: {
            customerId,
            installationId,
            planId
          }
        })
      });

      if (!rzpResp.ok) {
        const errText = await rzpResp.text();
        console.error('Razorpay order creation failed:', errText);
        return createErrorResponse(502, 'RAZORPAY_GATEWAY_ERROR', `Payment gateway error (${rzpResp.status})`);
      }

      const rzpData: any = await rzpResp.json();
      if (rzpData.id) {
        razorpayOrderId = rzpData.id;
      }
    } catch (err) {
      console.error('Razorpay API call exception:', err);
      return createErrorResponse(502, 'RAZORPAY_CONNECTION_ERROR', 'Failed to connect to Razorpay payment gateway.');
    }
  }

  // 7. Write order tracking record to `payments` collection
  const paymentRecord = {
    paymentId: razorpayOrderId,
    razorpayOrderId,
    installationId,
    customerId,
    planId,
    planName,
    durationDays,
    amountInr,
    status: 'INITIATED',
    createdAtEpochMs: now
  };

  await setDocument(env, 'payments', razorpayOrderId, paymentRecord);

  const responseBody: ApiResponse = {
    success: true,
    data: {
      razorpayOrderId,
      amountPaise,
      keyId: env.RAZORPAY_KEY_ID || '',
      planId,
      amountInr
    }
  };

  return new Response(JSON.stringify(responseBody), {
    status: 201,
    headers: { 'Content-Type': 'application/json' }
  });
}

/**
 * Handles POST /api/v1/orders/verify
 * Client fallback verification when Razorpay webhook delivery is delayed or when checkout modal closes.
 */
export async function handleVerifyOrder(request: Request, env: Env): Promise<Response> {
  const authResult = await authenticateRequest(request, env);
  if (authResult.errorResponse) return authResult.errorResponse;
  const identity = authResult.identity!;

  let body: {
    razorpayOrderId?: string;
    razorpayPaymentId?: string;
    razorpaySignature?: string;
    errorCode?: string;
  };
  try {
    body = await request.json();
  } catch {
    return createErrorResponse(400, 'INVALID_JSON', 'Request body must be valid JSON.');
  }

  const rawOrderId = typeof body.razorpayOrderId === 'string' ? body.razorpayOrderId : '';
  if (rawOrderId.length > 100) {
    return createErrorResponse(400, 'INVALID_ORDER_ID', 'razorpayOrderId exceeds maximum allowed length.');
  }
  const orderId = rawOrderId.trim();
  if (!orderId) {
    return createErrorResponse(400, 'MISSING_ORDER_ID', 'razorpayOrderId is required.');
  }

  const paymentDoc = await getDocument(env, 'payments', orderId);
  if (!paymentDoc) {
    return createErrorResponse(404, 'ORDER_NOT_FOUND', `Order '${orderId}' was not found.`);
  }

  // 1. Handle explicit payment cancellation / error dismissal by user
  if (body.errorCode && body.errorCode === 'PAYMENT_CANCELLED') {
    if (paymentDoc.status === 'INITIATED') {
      paymentDoc.status = 'FAILED';
      paymentDoc.updatedAtEpochMs = Date.now();
      await setDocument(env, 'payments', orderId, paymentDoc);
    }
    const resp: ApiResponse = { success: true, data: { status: 'FAILED', message: 'Payment marked as failed/cancelled.' } };
    return new Response(JSON.stringify(resp), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  // 2. If already settled by webhook, return success instantly
  if (paymentDoc.status === 'SUCCESS') {
    const resp: ApiResponse = { success: true, data: { status: 'SUCCESS', message: 'Order already settled.' } };
    return new Response(JSON.stringify(resp), { status: 200, headers: { 'Content-Type': 'application/json' } });
  }

  // 3. Verify payment signature or check Razorpay directly if captured
  const now = Date.now();
  let isVerifiedSuccess = false;

  if (typeof body.razorpayPaymentId === 'string' && typeof body.razorpaySignature === 'string' && env.RAZORPAY_WEBHOOK_SECRET) {
    if (body.razorpayPaymentId.length > 100 || body.razorpaySignature.length > 256) {
      return createErrorResponse(400, 'INVALID_PAYMENT_PAYLOAD', 'Payment ID or signature exceeds maximum allowed length.');
    }
    // Verify HMAC SHA-256 (`order_id + '|' + payment_id`)
    const cryptoSecret = env.RAZORPAY_WEBHOOK_SECRET || 'vendsoft_authoritative_worker_secret_v1';
    const msg = `${orderId}|${body.razorpayPaymentId}`;
    const enc = new TextEncoder();
    const key = await crypto.subtle.importKey('raw', enc.encode(cryptoSecret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    const signatureBytes = await crypto.subtle.sign('HMAC', key, enc.encode(msg));
    const hexSignature = Array.from(new Uint8Array(signatureBytes)).map((b) => b.toString(16).padStart(2, '0')).join('');
    if (hexSignature === body.razorpaySignature) {
      isVerifiedSuccess = true;
    }
  } else if (!env.FIRESTORE_SA_KEY && body.razorpayPaymentId) {
    // Local dev simulation (`wrangler dev`) when Service Account is not injected
    isVerifiedSuccess = true;
  }

  if (!isVerifiedSuccess && env.RAZORPAY_KEY_ID && env.RAZORPAY_KEY_SECRET) {
    // Check Razorpay REST API directly
    try {
      const authHeader = 'Basic ' + btoa(`${env.RAZORPAY_KEY_ID}:${env.RAZORPAY_KEY_SECRET}`);
      const rzpResp = await fetch(`https://api.razorpay.com/v1/orders/${orderId}/payments`, {
        method: 'GET',
        headers: { 'Authorization': authHeader }
      });
      if (rzpResp.ok) {
        const rzpData: any = await rzpResp.json();
        const items = rzpData.items || [];
        for (const item of items) {
          if (item.status === 'captured') {
            isVerifiedSuccess = true;
            body.razorpayPaymentId = item.id;
            break;
          }
        }
      }
    } catch (err) {
      console.error('Razorpay fallback verification check error:', err);
    }
  }

  if (!isVerifiedSuccess) {
    return createErrorResponse(400, 'PAYMENT_NOT_CAPTURED', 'Payment verification failed or payment not captured yet.');
  }

  // 4. Deterministic Subscription Discovery
  const customerId = paymentDoc.customerId;
  const installationId = paymentDoc.installationId;
  const durationDays = typeof paymentDoc.durationDays === 'number' ? paymentDoc.durationDays : 365;
  const planId = paymentDoc.planId || 'PRO_YEARLY';
  const planName = paymentDoc.planName || 'Pro Annual License';

  const { subscriptionId: foundId } = await findSubscription(env, customerId, DiscoveryStrategy.PAYMENT);
  let subscriptionId = foundId;

  if (!subscriptionId) {
    subscriptionId = `sub_${generateShortId()}`;
  }

  let finalSubscriptionId = subscriptionId;
  let requireRefund = false;
  let successResp: ApiResponse | null = null;

  try {
    await LockService.withLock(
      env,
      'sub_lock',
      subscriptionId,
      30000,
      { customerId, subscriptionId },
      async () => {
        // 6. Authoritative Read
        let subDoc = null;
        if (subscriptionId.startsWith('TRIAL_')) {
          const hardwareId = subscriptionId.replace('TRIAL_', '');
          const trial = await getDocument(env, 'hardware_trials', hardwareId);
          if (trial) {
            subDoc = {
              subscriptionId,
              customerId: trial.customerId,
              activeInstallationId: trial.hardwareId,
              planId: 'FREE_TRIAL_30',
              status: trial.expiresAtEpochMs > now ? 'ACTIVE' : 'EXPIRED',
              expiresAtEpochMs: trial.expiresAtEpochMs,
              startsAtEpochMs: trial.startsAtEpochMs
            };
          }
        } else {
          subDoc = await getDocument(env, 'subscriptions', subscriptionId);
        }

        // 7. Validate (Order Lifecycle Saga)
        if (subDoc && subDoc.status === 'ACTIVE' && subDoc.expiresAtEpochMs > now) {
          if (subDoc.activeInstallationId && subDoc.activeInstallationId !== installationId) {
            // Ownership conflict!
            requireRefund = true;
          }
        }

        if (requireRefund) {
          // FSM: CREATED -> REFUND_PENDING
          await setDocument(env, 'payments', orderId, {
            ...paymentDoc,
            status: 'REFUND_PENDING',
            updatedAtEpochMs: Date.now()
          });
        } else {
          // Normal Settlement (FSM: CREATED -> SUCCESS)
          let currentExpiresAt = subDoc && typeof subDoc.expiresAtEpochMs === 'number' ? subDoc.expiresAtEpochMs : now;
          const baseTime = currentExpiresAt > now ? currentExpiresAt : now;
          const newExpiresAt = baseTime + (durationDays * 86400000);

          const leasePayload = {
            subscriptionId,
            customerId,
            activeInstallationId: installationId,
            planId,
            planName,
            startsAtEpochMs: subDoc && subDoc.startsAtEpochMs ? subDoc.startsAtEpochMs : now,
            expiresAtEpochMs: newExpiresAt,
            maxCustomers: planId === 'PRO_YEARLY' ? 10000 : 1000,
            allowWhatsAppAutoSend: true,
            allowThermalPrinting: true,
            issuedAt: now
          };

          const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
          const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

          const batchWrites: Array<{ collectionPath: string; documentId: string; data: Record<string, any> }> = [
            {
              collectionPath: 'payments',
              documentId: orderId,
              data: {
                ...paymentDoc,
                status: 'SUCCESS',
                razorpayPaymentId: body.razorpayPaymentId || null,
                razorpaySignature: body.razorpaySignature || null,
                updatedAtEpochMs: now
              }
            },
            {
              collectionPath: 'subscriptions',
              documentId: subscriptionId,
              data: {
                subscriptionId,
                customerId,
                activeInstallationId: installationId,
                planId,
                planName,
                status: 'ACTIVE',
                startsAtEpochMs: leasePayload.startsAtEpochMs,
                expiresAtEpochMs: newExpiresAt,
                signedLeaseToken,
                updatedAtEpochMs: now
              }
            }
          ];

          await commitAtomicWrites(env, batchWrites);

          successResp = {
            success: true,
            data: {
              status: 'SUCCESS',
              subscriptionId,
              activeInstallationId: installationId,
              expiresAtEpochMs: newExpiresAt,
              signedLeaseToken
            }
          };
        }
      }
    );
  } catch (err: any) {
    if (err.code === 'ALREADY_EXISTS') {
      return createErrorResponse(409, 'CONCURRENT_MUTATION_LOCKED', 'Subscription is currently locked by another process. Please try again.');
    }
    throw err;
  }

  if (requireRefund) {
    // 9. Execute External Saga (Outside Mutex)
    const currentPaymentDoc = await getDocument(env, 'payments', orderId);
    if (currentPaymentDoc) {
      const refundResp = await executeRefundSaga(env, currentPaymentDoc, body.razorpayPaymentId || '');
      // We wrap the internal webhook response in our standard ApiResponse format
      const refundData = await refundResp.json() as any;
      if (refundData.success) {
        return createErrorResponse(400, 'ORDER_INVALIDATED', 'Subscription ownership changed. Your payment has been automatically refunded.');
      } else {
        return createErrorResponse(500, 'REFUND_ERROR', 'Order invalidated but automated refund failed. Please contact support.');
      }
    }
  }

  return new Response(JSON.stringify(successResp), { status: 200, headers: { 'Content-Type': 'application/json' } });
}
