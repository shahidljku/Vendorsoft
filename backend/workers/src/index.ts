import { Env } from './types';
import { routeRequest } from './router';
import { createErrorResponse } from './authGuard';

/**
 * Main Entry Point for VendSoft Cloudflare Workers Control Plane (`api.vendsoft.app`).
 * Catches unhandled runtime exceptions and returns clean, JSON-formatted error responses.
 */
function applySecurityHeaders(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload');
  headers.set('X-Content-Type-Options', 'nosniff');
  headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  headers.set('Content-Security-Policy', "default-src 'none'; frame-ancestors 'none';");
  headers.set('Permissions-Policy', 'geolocation=(), camera=(), microphone=()');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      const response = await routeRequest(request, env, ctx);
      return applySecurityHeaders(response);
    } catch (err: any) {
      console.error('Unhandled Worker API Gateway Exception:', err);
      const errResponse = createErrorResponse(
        500,
        'INTERNAL_SERVER_ERROR',
        'An unexpected server error occurred while processing the request.'
      );
      return applySecurityHeaders(errResponse);
    }
  },

  /**
   * Phase 10: Asynchronous Queue Consumer (Workload Isolation)
   */
  async queue(batch: MessageBatch<any>, env: Env, ctx: ExecutionContext): Promise<void> {
    const { QueueConsumerService } = await import('./services/queueConsumer');
    await QueueConsumerService.processBatch(batch, env, ctx);
  },

  /**
   * Phase 10: Cron Triggers (Data Lifecycle Management)
   */
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    const { DataLifecycleService } = await import('./services/dataLifecycle');
    await DataLifecycleService.runDailyCleanup(env, ctx);
  }
};
