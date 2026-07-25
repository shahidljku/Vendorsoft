export class InstallationFSM {
    static transition(installation: any, action: 'ACTIVATE' | 'REVOKE' | 'BAN'): string {
        const currentStatus = installation.status || null;

        switch (action) {
            case 'ACTIVATE':
                if (currentStatus === null || currentStatus === 'REVOKED' || currentStatus === 'BANNED') return 'ACTIVE';
                break;
            case 'REVOKE':
                if (currentStatus === 'ACTIVE') return 'REVOKED';
                break;
            case 'BAN':
                // Can ban an active or revoked device
                if (currentStatus === 'ACTIVE' || currentStatus === 'REVOKED') return 'BANNED';
                break;
        }

        throw new Error(`ILLEGAL_TRANSITION: Cannot transition installation from ${currentStatus} via ${action}`);
    }
}
