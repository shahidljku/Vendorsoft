import { ResiliencePolicy } from './policies';
import { RequestContext } from '../logger';

export type CircuitState = 'CLOSED' | 'OPEN' | 'HALF_OPEN';

export class CircuitBreakerError extends Error {
  constructor(public circuitName: string) {
    super(`Circuit Breaker [${circuitName}] is OPEN. Fast-failing request.`);
    this.name = 'CircuitBreakerError';
  }
}

export class CircuitBreaker {
  private state: CircuitState = 'CLOSED';
  private failureCount = 0;
  private nextAttemptAt = 0;

  constructor(
    private readonly name: string,
    private readonly policy: ResiliencePolicy['circuitBreaker']
  ) {}

  /**
   * Evaluates the circuit state and executes the payload if allowed.
   * Emits objective telemetry for state transitions and fast-failures.
   */
  async execute<T>(
    ctx: RequestContext,
    operation: () => Promise<T>,
    isFailure: (error: any) => boolean = () => true
  ): Promise<T> {
    if (this.state === 'OPEN') {
      if (Date.now() >= this.nextAttemptAt) {
        this.transitionTo(ctx, 'HALF_OPEN');
      } else {
        // Log telemetry for explicit fast failure
        await ctx.telemetry.measure('circuit.fast_fail', { circuit: this.name }, async () => {});
        throw new CircuitBreakerError(this.name);
      }
    }

    try {
      const result = await operation();
      if (this.state === 'HALF_OPEN') {
        this.transitionTo(ctx, 'CLOSED');
      } else {
        // Successful execution in CLOSED state slowly heals any existing failure counts
        this.failureCount = Math.max(0, this.failureCount - 1);
      }
      return result;
    } catch (error) {
      if (isFailure(error)) {
        this.recordFailure(ctx);
      }
      throw error;
    }
  }

  private recordFailure(ctx: RequestContext) {
    this.failureCount++;
    if (this.state === 'HALF_OPEN' || this.failureCount >= this.policy.failureThreshold) {
      this.transitionTo(ctx, 'OPEN');
    }
  }

  private transitionTo(ctx: RequestContext, newState: CircuitState) {
    const oldState = this.state;
    this.state = newState;

    if (newState === 'OPEN') {
      this.nextAttemptAt = Date.now() + this.policy.resetTimeoutMs;
      this.failureCount = 0;
    }

    const metricName = `circuit.${newState.toLowerCase()}`;
    // Emit telemetry natively for state transitions to assist in incident analysis
    ctx.telemetry.measure(metricName, { circuit: this.name, previous: oldState }, async () => {}).catch(() => {});
    
    ctx.logger.warn(`Circuit Breaker [${this.name}] transitioned: ${oldState} -> ${newState}`);
  }
  
  // For testing transparency
  getState(): CircuitState { return this.state; }
  getFailureCount(): number { return this.failureCount; }
}

// Global isolate-local circuit breaker instances
export const circuitBreakers = new Map<string, CircuitBreaker>();

/**
 * Retrieves or initializes an isolate-local Circuit Breaker singleton for a given dependency.
 */
export function getCircuitBreaker(name: string, policy: ResiliencePolicy['circuitBreaker']): CircuitBreaker {
  if (!circuitBreakers.has(name)) {
    circuitBreakers.set(name, new CircuitBreaker(name, policy));
  }
  return circuitBreakers.get(name)!;
}
