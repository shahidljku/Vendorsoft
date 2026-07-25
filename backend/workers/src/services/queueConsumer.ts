import { RequestContext, LoggerService, TelemetryService } from './logger';
import { Env } from '../types';
import { getDocument } from './firestore';
import { PaymentService } from './paymentService';

export interface WebhookQueueMessage {
  receiptId: string;
  eventId: string;
  type: string;
  orderId: string;
  signature: string;
}

export class QueueConsumerService {
  /**
   * Processes a batch of asynchronous background messages.
   * Leverages idempotency and explicit retries for workload isolation.
   */
  static async processBatch(batch: MessageBatch<WebhookQueueMessage>, env: Env, ctx: ExecutionContext) {
    const traceId = `qc_${crypto.randomUUID()}`;
    const loggerCtx: RequestContext = { 
      traceId, 
      logger: new LoggerService(traceId), 
      telemetry: new TelemetryService(traceId), 
      execCtx: ctx 
    };
    loggerCtx.logger.info(`Processing queue batch of size: ${batch.messages.length}`);

    for (const message of batch.messages) {
      const payload = message.body;
      
      try {
        // 1. Fetch full durable payload from Firestore via receipt
        const receipt = await getDocument(loggerCtx, env, 'webhook_receipts', payload.receiptId);
        
        if (!receipt) {
          loggerCtx.logger.error(`Webhook receipt not found for ${payload.receiptId}. Dropping message.`);
          // We ack it (don't retry) because if it's missing from DB, it's permanently unrecoverable
          continue; 
        }

        // 2. Prepare settlement
        const verifiedPayment = {
          orderId: payload.orderId,
          paymentId: receipt.payload?.payload?.payment?.entity?.id,
          signature: payload.signature
        };

        // 3. Execute Idempotent Settlement
        const settlementResult = await PaymentService.settleOrder(loggerCtx, env, verifiedPayment, payload.orderId);

        loggerCtx.logger.info(`Webhook ${payload.eventId} processed. Status: ${settlementResult.status}`);
        
        // 4. Message automatically acknowledged by returning successfully
      } catch (err: any) {
        if (err.code === 'CONCURRENT_MUTATION_LOCKED' || err.code === 'CONCURRENT_REFUND_IN_PROGRESS') {
          loggerCtx.logger.warn(`Transient concurrency lock for ${payload.eventId}. Retrying message.`);
          message.retry(); // Explicitly push back to queue for exponential backoff
        } else if (err.code === 'ORDER_INVALIDATED') {
          loggerCtx.logger.info(`Order already invalidated for ${payload.eventId}. Dropping message.`);
          // Automatically acked, no retry needed
        } else {
          loggerCtx.logger.error(`Fatal settlement error for ${payload.eventId}:`, err);
          // For truly fatal unknown errors, we also retry until the Dead Letter Queue (DLQ) threshold is hit
          message.retry();
        }
      }
    }
  }
}
