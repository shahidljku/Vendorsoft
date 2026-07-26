export class TransferFSM {
    static transition(transfer: any, action: 'REQUEST' | 'APPROVE' | 'REJECT' | 'CANCEL'): string {
        const currentStatus = transfer.status || null;

        switch (action) {
            case 'REQUEST':
                if (currentStatus === null) return 'PENDING';
                break;
            case 'APPROVE':
                if (currentStatus === 'PENDING' || currentStatus === 'RATE_LIMITED') return 'APPROVED';
                break;
            case 'REJECT':
                if (currentStatus === 'PENDING' || currentStatus === 'RATE_LIMITED') return 'REJECTED';
                break;
            case 'CANCEL':
                if (currentStatus === 'PENDING' || currentStatus === 'RATE_LIMITED') return 'CANCELLED';
                break;
        }

        throw new Error(`ILLEGAL_TRANSITION: Cannot transition transfer from ${currentStatus} via ${action}`);
    }
}
