export class SubscriptionFSM {
    static transition(subscription: any, action: 'ACTIVATE' | 'CANCEL'): string {
        const currentStatus = subscription.status || null;

        switch (action) {
            case 'ACTIVATE':
                if (currentStatus === null || currentStatus === 'ACTIVE' || currentStatus === 'CANCELLED' || currentStatus === 'EXPIRED' || currentStatus === 'REVOKED') return 'ACTIVE';
                break;
            case 'CANCEL':
                if (currentStatus === null || currentStatus === 'ACTIVE' || currentStatus === 'CANCELLED' || currentStatus === 'EXPIRED' || currentStatus === 'REVOKED') return 'CANCELLED';
                break;
        }

        throw new Error(`ILLEGAL_TRANSITION: Cannot transition subscription from ${currentStatus} via ${action}`);
    }
}
