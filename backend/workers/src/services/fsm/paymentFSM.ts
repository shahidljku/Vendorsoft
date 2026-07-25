export class PaymentFSM {
    static transition(payment: any, action: 'INITIATE' | 'FAIL' | 'SETTLE' | 'REQUEST_REFUND' | 'COMPLETE_REFUND'): string {
        const currentStatus = payment.status || null;

        switch (action) {
            case 'INITIATE':
                if (currentStatus === null) return 'INITIATED';
                break;
            case 'FAIL':
                if (currentStatus === 'INITIATED') return 'FAILED';
                break;
            case 'SETTLE':
                if (currentStatus === 'INITIATED') return 'SUCCESS';
                break;
            case 'REQUEST_REFUND':
                if (currentStatus === 'SUCCESS' || currentStatus === 'INITIATED') return 'REFUND_PENDING';
                break;
            case 'COMPLETE_REFUND':
                if (currentStatus === 'REFUND_PENDING') return 'REFUNDED';
                break;
        }

        throw new Error(`ILLEGAL_TRANSITION: Cannot transition payment from ${currentStatus} via ${action}`);
    }
}
