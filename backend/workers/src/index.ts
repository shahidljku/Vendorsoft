import { Env } from './types';
import { routeRequest } from './router';
import { createErrorResponse } from './authGuard';

/**
 * Main Entry Point for VendSoft Cloudflare Workers Control Plane (`api.vendsoft.app`).
 * Catches unhandled runtime exceptions and returns clean, JSON-formatted error responses.
 */
export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    try {
      return await routeRequest(request, env);
    } catch (err: any) {
      console.error('Unhandled Worker API Gateway Exception:', err);
      return createErrorResponse(
        500,
        'INTERNAL_SERVER_ERROR',
        'An unexpected server error occurred while processing the request.'
      );
    }
  }
};
