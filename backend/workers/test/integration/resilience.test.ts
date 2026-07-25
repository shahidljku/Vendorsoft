import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { 
  executeWithTimeout, 
  TimeoutError,
  withRetry, 
  CircuitBreaker, 
  CircuitBreakerError 
} from '../../src/services/resilience';

describe('Resilience Primitives', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  describe('executeWithTimeout', () => {
    it('resolves if operation completes before timeout', async () => {
      const operation = vi.fn().mockResolvedValue('success');
      const result = await executeWithTimeout(1000, operation);
      expect(result).toBe('success');
    });

    it('rejects with TimeoutError if operation exceeds limit', async () => {
      const operation = async (signal: AbortSignal) => {
        return new Promise((_, reject) => {
          signal.addEventListener('abort', () => {
            const err = new Error('The operation was aborted');
            err.name = 'AbortError';
            reject(err);
          });
        });
      };

      const promise = executeWithTimeout(500, operation);
      vi.advanceTimersByTime(501);

      await expect(promise).rejects.toThrow(TimeoutError);
    });
  });

  describe('withRetry', () => {
    it('retries with exponential backoff on transient errors', async () => {
      let attempts = 0;
      const operation = vi.fn().mockImplementation(async () => {
        attempts++;
        if (attempts < 3) throw new Error('Transient 503');
        return 'success';
      });

      const policy = { maxRetries: 3, baseDelayMs: 100, maxDelayMs: 1000 };
      
      const promise = withRetry(policy, operation, (err) => err.message.includes('503'));
      
      // Attempt 1 fails instantly.
      // Attempt 2 backoff is roughly 100ms.
      await vi.advanceTimersByTimeAsync(150);
      
      // Attempt 3 backoff is roughly 200ms.
      await vi.advanceTimersByTimeAsync(250);

      const result = await promise;
      expect(result).toBe('success');
      expect(attempts).toBe(3);
    });

    it('throws immediately on non-transient errors without retrying', async () => {
      const operation = vi.fn().mockRejectedValue(new Error('Fatal Auth Error'));
      const policy = { maxRetries: 3, baseDelayMs: 100, maxDelayMs: 1000 };
      
      const promise = withRetry(policy, operation, (err) => err.message.includes('503'));
      
      await expect(promise).rejects.toThrow('Fatal Auth Error');
      expect(operation).toHaveBeenCalledTimes(1);
    });
  });

  describe('CircuitBreaker', () => {
    const mockCtx: any = {
      logger: { warn: vi.fn(), error: vi.fn() },
      telemetry: { measure: vi.fn().mockImplementation(async (_, __, cb) => cb()) }
    };

    it('opens after threshold failures and emits telemetry', async () => {
      const policy = { failureThreshold: 3, resetTimeoutMs: 10000 };
      const cb = new CircuitBreaker('test-db', policy);

      const operation = vi.fn().mockRejectedValue(new Error('DB Down'));

      // Fail 3 times
      for (let i = 0; i < 3; i++) {
        await expect(cb.execute(mockCtx, operation)).rejects.toThrow('DB Down');
      }

      expect(cb.getState()).toBe('OPEN');
      expect(mockCtx.telemetry.measure).toHaveBeenCalledWith(
        'circuit.open', 
        expect.objectContaining({ circuit: 'test-db', previous: 'CLOSED' }),
        expect.any(Function)
      );

      // Subsequent call fast-fails
      await expect(cb.execute(mockCtx, operation)).rejects.toThrow(CircuitBreakerError);
    });

    it('transitions to HALF_OPEN after timeout and heals on success', async () => {
      const policy = { failureThreshold: 2, resetTimeoutMs: 5000 };
      const cb = new CircuitBreaker('test-api', policy);

      const failOp = vi.fn().mockRejectedValue(new Error('API Down'));
      await expect(cb.execute(mockCtx, failOp)).rejects.toThrow();
      await expect(cb.execute(mockCtx, failOp)).rejects.toThrow();
      
      expect(cb.getState()).toBe('OPEN');

      // Advance past reset timeout
      vi.advanceTimersByTime(5001);

      const successOp = vi.fn().mockResolvedValue('ok');
      const result = await cb.execute(mockCtx, successOp);
      
      expect(result).toBe('ok');
      expect(cb.getState()).toBe('CLOSED');
      expect(cb.getFailureCount()).toBe(0);
    });
  });
});
