export class SubscriptionFSM {
    static transition(subscription: any, action: 'ACTIVATE' | 'CANCEL'): string {
        const currentStatus = subscription.status || null;

        switch (action) {
            case 'ACTIVATE':
                if (currentStatus === null || currentStatus === 'ACTIVE' || currentStatus === 'CANCELLED') return 'ACTIVE';
                break;
            case 'CANCEL':
                if (currentStatus === 'ACTIVE') return 'CANCELLED';
                break;
        }

        throw new Error(`ILLEGAL_TRANSITION: Cannot transition subscription from ${currentStatus} via ${action}`);
    }
}
