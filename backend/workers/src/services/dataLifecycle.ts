import { RequestContext, LoggerService, TelemetryService } from './logger';
import { Env } from '../types';
import { queryCollection, deleteDocument } from './firestore';

export const RetentionPolicies = {
  AUDIT_LOGS: 90,        // Days to retain security audit logs
  WEBHOOK_RECEIPTS: 30,  // Days to retain webhook payloads for debug/replay
  PENDING_TRANSFERS: 7,  // Days before an incomplete device transfer expires
};

export class DataLifecycleService {
  
  /**
   * Executed via Cloudflare Workers Cron Triggers (`scheduled`).
   * Iterates through retention policies and purges expired documents.
   */
  static async runDailyCleanup(env: Env, ctx: ExecutionContext): Promise<void> {
    const traceId = `cron_${crypto.randomUUID()}`;
    const loggerCtx: RequestContext = { 
      traceId, 
      logger: new LoggerService(traceId), 
      telemetry: new TelemetryService(traceId), 
      execCtx: ctx 
    };
    loggerCtx.logger.info('Starting daily Data Lifecycle cleanup job...');

    try {
      await this.cleanupCollection(loggerCtx, env, 'audit_logs', 'timestamp', RetentionPolicies.AUDIT_LOGS);
      await this.cleanupCollection(loggerCtx, env, 'webhook_receipts', 'receivedAt', RetentionPolicies.WEBHOOK_RECEIPTS);
      
      // Transfers have a compound requirement: must be 'pending' AND old.
      // For simplicity in the REST abstraction, we'll fetch old transfers and filter locally.
      await this.cleanupExpiredTransfers(loggerCtx, env, RetentionPolicies.PENDING_TRANSFERS);
      
      loggerCtx.logger.info('Daily Data Lifecycle cleanup completed successfully.');
    } catch (err) {
      loggerCtx.logger.error('Data Lifecycle cleanup encountered an error:', err);
    }
  }

  private static async cleanupCollection(ctx: RequestContext, env: Env, collection: string, timeField: string, daysToRetain: number) {
    const cutoffDate = new Date(Date.now() - (daysToRetain * 24 * 60 * 60 * 1000)).toISOString();
    ctx.logger.info(`Cleaning ${collection} older than ${cutoffDate} (${daysToRetain} days)`);

    const expiredDocs = await queryCollection(ctx, env, collection, [
      { field: timeField, op: 'LESS_THAN', value: cutoffDate }
    ]);

    let deleted = 0;
    for (const doc of expiredDocs) {
      const id = doc.id || doc.receiptId || doc.logId;
      if (id) {
        await deleteDocument(ctx, env, collection, id);
        deleted++;
      }
    }
    
    ctx.logger.info(`Purged ${deleted} documents from ${collection}.`);
  }

  private static async cleanupExpiredTransfers(ctx: RequestContext, env: Env, daysToRetain: number) {
    const cutoffDate = new Date(Date.now() - (daysToRetain * 24 * 60 * 60 * 1000)).toISOString();
    
    // We only delete 'pending' transfers. 'completed' transfers are retained indefinitely.
    const expiredPendingTransfers = await queryCollection(ctx, env, 'device_transfers', [
      { field: 'createdAt', op: 'LESS_THAN', value: cutoffDate }
    ]);

    let deleted = 0;
    for (const transfer of expiredPendingTransfers) {
      if (transfer.status === 'pending') {
        await deleteDocument(ctx, env, 'device_transfers', transfer.id);
        deleted++;
      }
    }
    
    ctx.logger.info(`Purged ${deleted} expired pending transfers.`);
  }
}
