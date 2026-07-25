import { RequestContext } from '../services/logger';
import { Env } from '../types';
import { HealthService } from '../services/healthService';

/**
 * Public health endpoint. Returns a shallow acknowledgment.
 */
export async function handleGetHealth(ctx: RequestContext, req: Request, env: Env): Promise<Response> {
  const result = HealthService.getShallowHealth();
  return new Response(JSON.stringify(result), {
    status: 200,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store'
    }
  });
}

/**
 * Admin diagnostics endpoint. Returns deep operational health state.
 */
export async function handleAdminDiagnostics(ctx: RequestContext, req: Request, env: Env): Promise<Response> {
  const url = new URL(req.url);
  const probe = url.searchParams.get('probe') || undefined;

  const result = await HealthService.getDiagnostics(ctx, env, probe);
  
  // Return 503 if infrastructure is completely missing or critically failed
  const httpStatus = result.status === 'unhealthy' ? 503 : 200;

  return new Response(JSON.stringify(result), {
    status: httpStatus,
    headers: {
      'Content-Type': 'application/json',
      'Cache-Control': 'no-store'
    }
  });
}
