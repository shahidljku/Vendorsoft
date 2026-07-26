export class InstallationFSM {
    static transition(installation: any, action: 'ACTIVATE' | 'REVOKE' | 'BAN'): string {
        const currentStatus = installation.status || null;

        switch (action) {
            case 'ACTIVATE':
                if (currentStatus === null || currentStatus === 'REVOKED' || currentStatus === 'BANNED' || currentStatus === 'ACTIVE') return 'ACTIVE';
                break;
            case 'REVOKE':
                if (currentStatus === null || currentStatus === 'ACTIVE' || currentStatus === 'REVOKED' || currentStatus === 'BANNED') return 'REVOKED';
                break;
            case 'BAN':
                if (currentStatus === null || currentStatus === 'ACTIVE' || currentStatus === 'REVOKED' || currentStatus === 'BANNED') return 'BANNED';
                break;
        }

        throw new Error(`ILLEGAL_TRANSITION: Cannot transition installation from ${currentStatus} via ${action}`);
    }
}
