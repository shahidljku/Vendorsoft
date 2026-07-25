import { ResiliencePolicy } from './policies';

/**
 * Standard utility to pause execution without blocking the isolate.
 */
const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

/**
 * Executes a Promise-based operation with an exponential backoff retry policy.
 * Only intended for operations with idempotent semantics.
 */
export async function withRetry<T>(
  policy: ResiliencePolicy['retry'],
  operation: (attempt: number) => Promise<T>,
  isRetryableError: (error: any) => boolean = () => true
): Promise<T> {
  let attempt = 0;
  
  while (true) {
    try {
      return await operation(attempt + 1);
    } catch (error) {
      if (attempt >= policy.maxRetries || !isRetryableError(error)) {
        throw error;
      }
      
      const backoffMs = Math.min(
        policy.maxDelayMs,
        policy.baseDelayMs * Math.pow(2, attempt)
      );
      
      // Add up to 20% jitter to prevent thundering herds
      const jitterMs = backoffMs * 0.2 * Math.random();
      const delayMs = backoffMs + jitterMs;
      
      await delay(delayMs);
      attempt++;
    }
  }
}
