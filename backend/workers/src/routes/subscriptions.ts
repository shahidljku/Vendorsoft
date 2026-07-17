import { Env, CompositeIdentity, ApiResponse } from '../types';
import { getDocument, queryCollection } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateSignedLeaseToken } from '../cryptoEngine';

/**
 * Handles GET /api/v1/subscriptions/status
 * Authoritative entitlement check enforcing the One Active Device Rule (`activeInstallationId == x-installation-id`).
 * See API_SPECIFICATION.md Section 2.3 & SECURITY_RULES.md Section 1.1 & 1.2.
 */
export async function handleGetSubscriptionStatus(request: Request, env: Env, identity: CompositeIdentity): Promise<Response> {
  try {
    // 1. Check system maintenance gate
    const config = await getDocument(env, 'system_configs', 'global');
    if (config && config.maintenanceMode === true) {
      return createErrorResponse(
        503,
        'MAINTENANCE_MODE',
        'VendSoft cloud sync is temporarily under scheduled maintenance. Offline billing continues normally.'
      );
    }

    // 2. Resolve customerId either from composite identity, url query param, or installation lookup
    const url = new URL(request.url);
    let customerId = identity.customerId || url.searchParams.get('customerId') || undefined;

    if (!customerId && identity.installationId) {
      const instDoc = await getDocument(env, 'installations', identity.installationId);
      if (instDoc && instDoc.customerId) {
        customerId = instDoc.customerId;
      }
    }

    if (!customerId) {
      return createErrorResponse(
        400,
        'MISSING_CUSTOMER_ID',
        'Unable to determine customer ID for this installation. Please register or provide customerId parameter.'
      );
    }

    // 3. Query active subscriptions for this customer
    const activeSubs = await queryCollection(env, 'subscriptions', [
      { field: 'customerId', op: 'EQUAL', value: customerId },
      { field: 'status', op: 'EQUAL', value: 'ACTIVE' }
    ]);

    if (!activeSubs || activeSubs.length === 0) {
      return createErrorResponse(
        404,
        'NO_ACTIVE_SUBSCRIPTION',
        `No active subscription found for customer '${customerId}'.`
      );
    }

    const sub = activeSubs[0];
    const now = Date.now();

    // 4. Enforce One Active Device Rule (`API_SPECIFICATION.md Section 2.3`)
    if (sub.activeInstallationId && identity.installationId && sub.activeInstallationId !== identity.installationId) {
      return createErrorResponse(
        403,
        'INSTALLATION_SUPERSEDED',
        'Another device is currently the active installation for this subscription. Please request a device transfer to activate this phone.',
        { activeInstallationId: sub.activeInstallationId }
      );
    }

    // 5. Check subscription expiration
    if (sub.expiresAtEpochMs && now > sub.expiresAtEpochMs) {
      return createErrorResponse(
        403,
        'SUBSCRIPTION_EXPIRED',
        'Your subscription license has expired. Please renew via checkout.'
      );
    }

    // 6. Generate cryptographic signedLeaseToken using Web Crypto HMAC-SHA256
    const secretKey = env.RSA_PRIVATE_KEY || 'MISSING_RSA_PRIVATE_KEY';
    const leasePayload = {
      subscriptionId: sub.subscriptionId,
      customerId: sub.customerId,
      activeInstallationId: sub.activeInstallationId || identity.installationId,
      hasActiveSubscription: true,
      planId: sub.planId || 'DEMO_FREE',
      planName: sub.planId === 'PRO_YEARLY' ? 'Pro Annual License' : '30-Day Free Demo License',
      startsAtEpochMs: sub.startsAtEpochMs || now,
      expiresAtEpochMs: sub.expiresAtEpochMs,
      maxCustomers: sub.planId === 'PRO_YEARLY' ? 10000 : 50,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };
    const signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);

    const responseData = {
      customerId: sub.customerId,
      installationId: identity.installationId || sub.activeInstallationId,
      activeInstallationId: sub.activeInstallationId || identity.installationId,
      hasActiveSubscription: true,
      status: sub.status || 'ACTIVE',
      planId: sub.planId || 'DEMO_FREE',
      planName: leasePayload.planName,
      startsAtEpochMs: sub.startsAtEpochMs || now,
      expiresAtEpochMs: sub.expiresAtEpochMs,
      maxCustomers: leasePayload.maxCustomers,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      signedLeaseToken
    };

    const responseWrapper: ApiResponse = {
      success: true,
      data: responseData
    };

    return new Response(JSON.stringify(responseWrapper), {
      status: 200,
      headers: {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      }
    });
  } catch (err: any) {
    console.error('Error in GET /api/v1/subscriptions/status:', err);
    return createErrorResponse(
      500,
      'SUBSCRIPTION_CHECK_FAILED',
      `Failed to retrieve subscription status: ${err.message || err}`
    );
  }
}
