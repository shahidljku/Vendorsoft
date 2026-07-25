export class TransferFSM {
    static transition(transfer: any, action: 'REQUEST' | 'APPROVE' | 'REJECT' | 'CANCEL'): string {
        const currentStatus = transfer.status || null;

        switch (action) {
            case 'REQUEST':
                if (currentStatus === null) return 'PENDING';
                break;
            case 'APPROVE':
                if (currentStatus === 'PENDING') return 'APPROVED';
                break;
            case 'REJECT':
                if (currentStatus === 'PENDING') return 'REJECTED';
                break;
            case 'CANCEL':
                if (currentStatus === 'PENDING') return 'CANCELLED';
                break;
        }

        throw new Error(`ILLEGAL_TRANSITION: Cannot transition transfer from ${currentStatus} via ${action}`);
    }
}
