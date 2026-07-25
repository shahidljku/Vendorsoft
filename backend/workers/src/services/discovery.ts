import { queryCollection, getDocument, setDocument } from './firestore';
import { Env } from '../types';

export enum DiscoveryStrategy {
    PAYMENT = 'PAYMENT',
    ADMIN_MANAGE = 'ADMIN_MANAGE',
    ADMIN_SEARCH = 'ADMIN_SEARCH',
    TRANSFER = 'TRANSFER',
    CUSTOMER_UPDATE = 'CUSTOMER_UPDATE',
    SUBSCRIPTION_STATUS = 'SUBSCRIPTION_STATUS'
}

export interface DiscoveryResult {
    subscriptionId: string | null;
    sub: any | null;
    isTrial: boolean;
    trialId?: string;
}

export class DiscoveryError extends Error {
    public code: string;
    public details?: any;
    constructor(code: string, message?: string, details?: any) {
        super(message || code);
        this.code = code;
        this.details = details;
    }
}

export async function findSubscription(
    env: Env,
    customerId: string,
    strategy: DiscoveryStrategy,
    identity?: any // Optional context for SUBSCRIPTION_STATUS trial creation
): Promise<DiscoveryResult> {
    
    // Mirrors historical behavior of webhooks.ts and orders.ts handleCreateOrder.
    // Intentionally queries all, checks find(ACTIVE), then sorts by expiresAtEpochMs.
    // Do not modify during Phase 2.
    if (strategy === DiscoveryStrategy.PAYMENT) {
        const subs = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
        let subscriptionId: string | null = null;
        let sub = null;
        let isTrial = false;
        
        const activeSub = subs.find((s: any) => s.status === 'ACTIVE');
        if (activeSub) {
            subscriptionId = activeSub.subscriptionId;
            sub = activeSub;
        } else if (subs.length > 0) {
            subs.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
            subscriptionId = subs[0].subscriptionId;
            sub = subs[0];
        } else {
            const trials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
            if (trials.length > 0) {
                trials.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
                subscriptionId = `TRIAL_${trials[0].hardwareId}`;
                sub = trials[0];
                isTrial = true;
            }
        }
        
        return { subscriptionId, sub, isTrial };
    }

    // Mirrors historical behavior of handleAdminManageSubscription.
    // Intentionally filters ACTIVE first and sorts BOTH active and all subs.
    // Do not modify during Phase 2.
    if (strategy === DiscoveryStrategy.ADMIN_MANAGE) {
        const subscriptions = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
        let activeSub: any = null;
        const activeSubs = subscriptions.filter((s: any) => s.status === 'ACTIVE');
        
        if (activeSubs.length > 0) {
            activeSubs.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
            activeSub = activeSubs[0];
        } else if (subscriptions.length > 0) {
            subscriptions.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
            activeSub = subscriptions[0];
        }
        
        let isTrial = false;
        let trialId = '';
        
        if (!activeSub) {
            const existingTrials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
            if (existingTrials.length > 0) {
                existingTrials.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
                activeSub = existingTrials[0];
                isTrial = true;
                trialId = activeSub.hardwareId || activeSub.installationId;
            }
        }
        
        const subscriptionId = activeSub?.subscriptionId || (isTrial ? `TRIAL_${trialId}` : null);
        return { subscriptionId, sub: activeSub, isTrial, trialId };
    }

    // Mirrors historical behavior of handleAdminSearchCustomers.
    // Intentionally preserves lack of sorting on subscriptions[0].
    // Do not modify during Phase 2.
    if (strategy === DiscoveryStrategy.ADMIN_SEARCH) {
        const subscriptions = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
        let activeSub = subscriptions.find((s: any) => s.status === 'ACTIVE') || subscriptions[0] || null;
        let isTrial = false;
        
        if (!activeSub) {
            const trials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
            if (trials.length > 0) {
                trials.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
                const trial = trials[0];
                activeSub = {
                    subscriptionId: `TRIAL_${trial.hardwareId}`,
                    planId: 'FREE_TRIAL_30',
                    status: trial.status === 'CANCELLED' ? 'CANCELLED' : (Date.now() > trial.expiresAtEpochMs ? 'EXPIRED' : 'ACTIVE'),
                    expiresAtEpochMs: trial.expiresAtEpochMs
                };
                isTrial = true;
            }
        }
        return { subscriptionId: activeSub?.subscriptionId || null, sub: activeSub, isTrial };
    }

    // Mirrors historical behavior of handleRequestTransfer.
    // Intentionally queries only for ACTIVE status directly at the DB level, and ignores EXPIRED subscriptions.
    // Do not modify during Phase 2.
    if (strategy === DiscoveryStrategy.TRANSFER) {
        let sub = null;
        let isTrial = false;
        
        const subs = await queryCollection(env, 'subscriptions', [
            { field: 'customerId', op: 'EQUAL', value: customerId },
            { field: 'status', op: 'EQUAL', value: 'ACTIVE' }
        ]);
        if (subs && subs.length > 0) {
            sub = subs[0];
        } else {
            const trials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
            if (trials && trials.length > 0) {
                trials.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
                const trial = trials[0];
                sub = {
                    subscriptionId: `TRIAL_${trial.hardwareId}`,
                    customerId: trial.customerId,
                    activeInstallationId: trial.hardwareId,
                    planId: 'FREE_TRIAL_30',
                    status: Date.now() > trial.expiresAtEpochMs ? 'EXPIRED' : 'ACTIVE',
                    expiresAtEpochMs: trial.expiresAtEpochMs
                };
                isTrial = true;
            }
        }
        return { subscriptionId: sub?.subscriptionId || null, sub, isTrial };
    }

    // Mirrors historical behavior of handleAdminUpdateCustomer.
    // Intentionally ignores status and sorts by createdAtEpochMs.
    // Do not modify during Phase 2.
    if (strategy === DiscoveryStrategy.CUSTOMER_UPDATE) {
        const subs = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
        let latestSub: any = null;
        let isTrial = false;
        
        if (subs && subs.length > 0) {
            subs.sort((a: any, b: any) => (b.createdAtEpochMs || 0) - (a.createdAtEpochMs || 0));
            latestSub = subs[0];
        } else {
            const trials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
            if (trials && trials.length > 0) {
                trials.sort((a: any, b: any) => (b.expiresAtEpochMs || 0) - (a.expiresAtEpochMs || 0));
                const trial = trials[0];
                latestSub = {
                    subscriptionId: `TRIAL_${trial.hardwareId}`,
                    planId: 'FREE_TRIAL_30',
                    activeInstallationId: trial.hardwareId,
                    status: Date.now() > trial.expiresAtEpochMs ? 'EXPIRED' : 'ACTIVE',
                    expiresAtEpochMs: trial.expiresAtEpochMs
                };
                isTrial = true;
            }
        }
        return { subscriptionId: latestSub?.subscriptionId || null, sub: latestSub, isTrial };
    }

    // Mirrors historical behavior of handleGetSubscriptionStatus.
    // Intentionally fails on CANCELLED, checks ACTIVE directly, and handles active trial creation.
    // Do not modify during Phase 2.
    if (strategy === DiscoveryStrategy.SUBSCRIPTION_STATUS) {
        if (!identity) throw new DiscoveryError('MISSING_IDENTITY', "SUBSCRIPTION_STATUS requires identity object");
        
        const allSubs = await queryCollection(env, 'subscriptions', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
        const cancelledSubs = allSubs.filter((s: any) => s.status === 'CANCELLED');
        
        const allTrials = await queryCollection(env, 'hardware_trials', [{ field: 'customerId', op: 'EQUAL', value: customerId }]);
        const cancelledTrials = allTrials.filter((t: any) => t.status === 'CANCELLED');

        if (cancelledSubs.length > 0 || cancelledTrials.length > 0) {
            throw new DiscoveryError('SUBSCRIPTION_CANCELLED');
        }

        const activeSubs = allSubs.filter((s: any) => s.status === 'ACTIVE');
        let sub: any = null;
        let isTrial = false;
        const now = Date.now();

        if (!activeSubs || activeSubs.length === 0) {
            if (!identity.installationId) {
                throw new DiscoveryError('NO_ACTIVE_SUBSCRIPTION');
            }

            const hardwareTrialDoc = await getDocument(env, 'hardware_trials', identity.installationId);
            const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;
            
            let trialStartsAt = now;
            let trialExpiresAt = now + THIRTY_DAYS_MS;

            if (!hardwareTrialDoc) {
                if (allTrials.length > 0) {
                    const existingTrial = allTrials.find((t: any) => t.status !== 'CANCELLED');
                    if (existingTrial) {
                        if (now > existingTrial.expiresAtEpochMs) {
                            throw new DiscoveryError('TRIAL_EXPIRED');
                        }
                        throw new DiscoveryError('INSTALLATION_SUPERSEDED', undefined, { activeInstallationId: existingTrial.hardwareId });
                    }
                }

                const newTrialId = identity.installationId;
                const newTrial = {
                    hardwareId: newTrialId,
                    customerId,
                    status: 'ACTIVE',
                    startsAtEpochMs: trialStartsAt,
                    expiresAtEpochMs: trialExpiresAt,
                    createdAtEpochMs: now
                };
                await setDocument(env, 'hardware_trials', newTrialId, newTrial);

                sub = {
                    subscriptionId: `TRIAL_${newTrialId}`,
                    customerId,
                    activeInstallationId: newTrialId,
                    planId: 'FREE_TRIAL_30',
                    status: 'ACTIVE',
                    expiresAtEpochMs: trialExpiresAt,
                    startsAtEpochMs: trialStartsAt
                };
                isTrial = true;
            } else {
                if (hardwareTrialDoc.customerId !== customerId) {
                    throw new DiscoveryError('TRIAL_OWNERSHIP_MISMATCH');
                }
                if (now > hardwareTrialDoc.expiresAtEpochMs) {
                    throw new DiscoveryError('TRIAL_EXPIRED');
                }

                sub = {
                    subscriptionId: `TRIAL_${hardwareTrialDoc.hardwareId}`,
                    customerId: hardwareTrialDoc.customerId,
                    activeInstallationId: hardwareTrialDoc.hardwareId,
                    planId: 'FREE_TRIAL_30',
                    status: 'ACTIVE',
                    expiresAtEpochMs: hardwareTrialDoc.expiresAtEpochMs,
                    startsAtEpochMs: hardwareTrialDoc.startsAtEpochMs
                };
                isTrial = true;
            }
        } else {
            sub = activeSubs[0];
        }

        return { subscriptionId: sub?.subscriptionId || null, sub, isTrial };
    }

    throw new Error(`Unsupported DiscoveryStrategy: ${strategy}`);
}
