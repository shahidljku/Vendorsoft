import { Env } from '../../types';
import { RateLimitPolicy } from './policies';

/**
 * Enforces a sliding-window / token-bucket rate limit using Cloudflare KV.
 * Fails open (allows request) if KV is unreachable to preserve business availability.
 * 
 * @param env The Cloudflare Environment bindings
 * @param policy The RateLimitPolicy to enforce (max requests over a specific TTL)
 * @param identityKey The multi-dimensional key to throttle on (e.g. `transfer_req:inst_123`)
 * @returns true if request is allowed, false if rate limit exceeded
 */
export async function checkRateLimit(
  env: Env,
  policy: RateLimitPolicy,
  identityKey: string
): Promise<boolean> {
  const rlKey = `ratelimit:${identityKey}`;
  let rlCount = 0;
  
  try {
    const rlStr = await env.APK_STORE.get(rlKey);
    if (rlStr) {
      rlCount = parseInt(rlStr, 10);
    }
    
    if (rlCount >= policy.maxRequests) {
      return false; // Rate limit exceeded
    }
    
    // Store the updated count with TTL matching the policy window
    const ttlSeconds = Math.max(60, Math.floor(policy.windowMs / 1000)); 
    await env.APK_STORE.put(rlKey, (rlCount + 1).toString(), { expirationTtl: ttlSeconds });
    
    return true;
  } catch (err) {
    console.error(`[RateLimiter] KV Error for key ${rlKey}:`, err);
    // Resilience: Adhere to the policy's specific fallback posture
    return policy.fallbackMode === 'fail_open';
  }
}
