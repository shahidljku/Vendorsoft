import { Env, CompositeIdentity, DomainMutation } from '../types';
import { getDocument, setDocument, commitAtomicWrites, logAuditEvent } from './firestore';
import { InstallationFSM } from './fsm/installationFSM';
import { LockService } from './lock';

export class InstallationService {
  /**
   * Bans a device at the hardware level, transitioning its Installation to BANNED.
   */
  static async banDevice(env: Env, hardwareId: string, adminUid: string): Promise<{ success: boolean; message: string }> {
    const doWork = async () => {
      const instDoc = await getDocument(env, 'installations', hardwareId);
      if (!instDoc) {
        const err: any = new Error('Device not found');
        err.code = 'NOT_FOUND';
        throw err;
      }
      
      const updated = {
        ...instDoc,
        status: InstallationFSM.transition(instDoc, 'BAN'),
        bannedAtEpochMs: Date.now(),
        bannedBy: adminUid
      };
      
      await setDocument(env, 'installations', hardwareId, updated);
      return { success: true, message: 'Device banned successfully' };
    };

    try {
      return await LockService.withLock(env, 'inst_lock', hardwareId, 30000, { requestId: adminUid }, doWork);
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Device is currently locked by another process.');
        newErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw newErr;
      }
      throw err;
    }
  }

  /**
   * Unbans a hardware device, transitioning its Installation back to ACTIVE.
   */
  static async unbanDevice(env: Env, hardwareId: string, adminUid: string): Promise<{ success: boolean; message: string }> {
    const doWork = async () => {
      const instDoc = await getDocument(env, 'installations', hardwareId);
      if (!instDoc) {
        const err: any = new Error('Device not found');
        err.code = 'NOT_FOUND';
        throw err;
      }
      
      const updated = {
        ...instDoc,
        status: 'ACTIVE', // Direct assignment to reset
        unbannedAtEpochMs: Date.now(),
        unbannedBy: adminUid
      };
      
      await setDocument(env, 'installations', hardwareId, updated);
      return { success: true, message: 'Device unbanned successfully' };
    };

    try {
      return await LockService.withLock(env, 'inst_lock', hardwareId, 30000, { requestId: adminUid }, doWork);
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Device is currently locked by another process.');
        newErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw newErr;
      }
      throw err;
    }
  }

  /**
   * Revokes an installation on a device.
   */
  static async revokeInstallation(env: Env, hardwareId: string, reason: string): Promise<{ success: boolean; message: string }> {
    const doWork = async () => {
      const instDoc = await getDocument(env, 'installations', hardwareId);
      if (!instDoc) {
        const err: any = new Error('Installation not found');
        err.code = 'NOT_FOUND';
        throw err;
      }
      
      const updated = {
        ...instDoc,
        status: InstallationFSM.transition(instDoc, 'REVOKE'),
        revokedAtEpochMs: Date.now(),
        revokedReason: reason
      };
      
      await setDocument(env, 'installations', hardwareId, updated);
      return { success: true, message: 'Installation revoked successfully' };
    };

    try {
      return await LockService.withLock(env, 'inst_lock', hardwareId, 30000, { requestId: 'revoke' }, doWork);
    } catch (err: any) {
      if (err.code === 'ALREADY_EXISTS') {
        const newErr: any = new Error('Installation is currently locked by another process.');
        newErr.code = 'CONCURRENT_MUTATION_LOCKED';
        throw newErr;
      }
      throw err;
    }
  }

  /**
   * Checks if a hardware trial has already been used on a device.
   * Throws an error if used, preventing double trials.
   */
  static async checkHardwareTrialEligibility(env: Env, hardwareId: string, identity: CompositeIdentity, inputMobileNumber: string, businessName: string, ipAddress: string, appVersion: string): Promise<{ success: boolean }> {
    const hardwareTrialDoc = await getDocument(env, 'hardware_trials', hardwareId);
    
    if (hardwareTrialDoc) {
      await logAuditEvent(env, 'REGISTRATION_REJECTED', {
          actorType: 'USER',
          actorId: identity.customerId || 'unknown',
          targetType: 'hardware_trials',
          targetId: hardwareId,
          details: 'Device has already consumed its lifetime trial.',
          timestampMs: Date.now(),
          mobileNumber: inputMobileNumber,
          businessName: businessName,
          reason: 'TRIAL_ALREADY_USED',
          ipAddress,
          appVersion
      });
      const err: any = new Error('This device has already consumed its lifetime trial.');
      err.code = 'TRIAL_ALREADY_USED';
      throw err;
    }
    
    return { success: true };
  }

  /**
   * Builds the atomic mutation required to activate a new installation.
   */
  static buildActivation(
    installationId: string, 
    customerId: string, 
    hardwareId: string, 
    identity: CompositeIdentity, 
    deviceModel: string | null, 
    fcmToken: string | null, 
    now: number
  ): DomainMutation {
    const writes = [{
      collectionPath: 'installations',
      documentId: installationId,
      data: {
        installationId,
        customerId,
        hardwareId,
        installationUuid: identity.installationUuid,
        firebaseUid: identity.uid,
        platform: identity.platform,
        appVersion: identity.appVersion,
        deviceModel,
        fcmToken,
        status: InstallationFSM.transition({}, 'ACTIVATE'),
        isBanned: false,
        createdAtEpochMs: now,
        lastSeenAtEpochMs: now
      }
    }];
    return { writes, result: undefined };
  }

  /**
   * Builds the atomic mutation required to revoke an installation.
   */
  static async buildRevocation(
    env: Env,
    hardwareId: string,
    reason: string,
    now: number
  ): Promise<DomainMutation> {
    const instDoc = await getDocument(env, 'installations', hardwareId);
    if (!instDoc) {
      const err: any = new Error('Installation not found');
      err.code = 'NOT_FOUND';
      throw err;
    }
    
    const writes = [{
      collectionPath: 'installations',
      documentId: hardwareId,
      data: {
        ...instDoc,
        status: InstallationFSM.transition(instDoc, 'REVOKE'),
        revokedAtEpochMs: now,
        revokedReason: reason,
        updatedAtEpochMs: now
      }
    }];
    
    return { writes, result: undefined };
  }
}
