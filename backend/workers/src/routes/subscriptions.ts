import { Env, CompositeIdentity, ApiResponse } from '../types';
import { getDocument, setDocument, queryCollection } from '../services/firestore';
import { createErrorResponse } from '../authGuard';
import { generateSignedLeaseToken } from '../cryptoEngine';
import { findSubscription, DiscoveryStrategy } from '../services/discovery';

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

    // 2.5 Check if customer is deactivated
    const customerDoc = await getDocument(env, 'customers', customerId);
    if (customerDoc && customerDoc.status === 'DEACTIVATED') {
      return createErrorResponse(
        403,
        'CUSTOMER_DEACTIVATED',
        'This account has been deactivated by the administrator.'
      );
    }

    // 2.75 Check for any explicitly CANCELLED subscriptions or trials & Find active subscriptions
    let sub: any = null;
    const now = Date.now();
    try {
      const { sub: foundSub } = await findSubscription(env, customerId, DiscoveryStrategy.SUBSCRIPTION_STATUS, identity);
      sub = foundSub;
    } catch (err: any) {
      if (err.code === 'SUBSCRIPTION_CANCELLED') {
        return createErrorResponse(403, 'SUBSCRIPTION_CANCELLED', 'Your subscription has been cancelled. Please activate a new plan.');
      } else if (err.code === 'NO_ACTIVE_SUBSCRIPTION') {
        return createErrorResponse(404, 'NO_ACTIVE_SUBSCRIPTION', `No active subscription found for customer '${customerId}', and hardware ID is missing for trial fallback.`);
      } else if (err.code === 'TRIAL_EXPIRED') {
        return createErrorResponse(403, 'TRIAL_EXPIRED', 'Your 30-Day Hardware Free Trial has expired. Please activate with a Pro plan.');
      } else if (err.code === 'INSTALLATION_SUPERSEDED') {
        return createErrorResponse(403, 'INSTALLATION_SUPERSEDED', 'Another device is currently the active installation for this trial. Please request a device transfer to activate this phone.', err.details);
      } else if (err.code === 'TRIAL_OWNERSHIP_MISMATCH') {
        return createErrorResponse(403, 'TRIAL_OWNERSHIP_MISMATCH', 'This device hardware trial is associated with a different customer account.');
      }
      throw err;
    }

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
    const offlineGracePeriodMs = 48 * 60 * 60 * 1000;
    const leasePayload = {
      // V1 Protocol Fields
      version: 1,
      licenseId: sub.subscriptionId,
      deviceId: sub.activeInstallationId || identity.installationId,
      status: "active",
      issuedAtEpochMs: now,
      expiresAtEpochMs: sub.expiresAtEpochMs,
      offlineValidUntilEpochMs: now + offlineGracePeriodMs,

      // Legacy Fields (for backward compatibility)
      subscriptionId: sub.subscriptionId,
      customerId: sub.customerId,
      activeInstallationId: sub.activeInstallationId || identity.installationId,
      hasActiveSubscription: true,
      planId: sub.planId,
      planName: sub.planId === 'PRO_YEARLY' ? 'Pro Annual License' : sub.planId === 'FREE_TRIAL_30' ? '30-Day Pro Trial' : 'Pro Monthly License',
      startsAtEpochMs: sub.startsAtEpochMs || now,
      maxCustomers: 10000,
      allowWhatsAppAutoSend: true,
      allowThermalPrinting: true,
      issuedAt: now
    };

    // Pillar 2: CPU & Database Exhaustion Patch
    let signedLeaseToken = sub.signedLeaseToken;
    let needsNewToken = false;

    if (signedLeaseToken) {
      try {
        const parts = signedLeaseToken.split('.');
        const payloadStr = atob(parts[0].replace(/-/g, '+').replace(/_/g, '/'));
        const parsed = JSON.parse(payloadStr);
        // Only regenerate if offline validity drops below 24 hours or key details change
        if (
          !parsed.offlineValidUntilEpochMs || 
          parsed.offlineValidUntilEpochMs < now + (24 * 60 * 60 * 1000) ||
          parsed.planId !== sub.planId ||
          parsed.deviceId !== leasePayload.deviceId
        ) {
          needsNewToken = true;
        }
      } catch (e) {
        needsNewToken = true;
      }
    } else {
      needsNewToken = true;
    }

    if (needsNewToken) {
      signedLeaseToken = await generateSignedLeaseToken(leasePayload, secretKey);
      
      // Save the generated token so future requests skip the RSA signing
      if (sub.subscriptionId && sub.subscriptionId.startsWith('TRIAL_')) {
        const hardwareId = sub.subscriptionId.replace('TRIAL_', '');
        const trialDoc = await getDocument(env, 'hardware_trials', hardwareId);
        if (trialDoc) {
          await setDocument(env, 'hardware_trials', hardwareId, {
            ...trialDoc,
            signedLeaseToken,
            updatedAtEpochMs: now
          });
        }
      } else if (sub.subscriptionId) {
        await setDocument(env, 'subscriptions', sub.subscriptionId, {
          ...sub,
          signedLeaseToken,
          updatedAtEpochMs: now
        });
      }
    }

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
