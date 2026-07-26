export interface ResiliencePolicy {
  retry: {
    maxRetries: number;
    baseDelayMs: number;
    maxDelayMs: number;
  };
  timeoutMs: number;
  circuitBreaker: {
    failureThreshold: number;
    resetTimeoutMs: number;
  };
}

export const ResiliencePolicies: Record<string, ResiliencePolicy> = {
  firestoreRead: {
    retry: { maxRetries: 3, baseDelayMs: 50, maxDelayMs: 3000 },
    timeoutMs: 5000,
    circuitBreaker: { failureThreshold: 5, resetTimeoutMs: 10000 }
  },
  firestoreIdempotentWrite: {
    retry: { maxRetries: 2, baseDelayMs: 100, maxDelayMs: 1500 },
    timeoutMs: 8000,
    circuitBreaker: { failureThreshold: 3, resetTimeoutMs: 15000 }
  },
  firestoreNonIdempotentWrite: {
    retry: { maxRetries: 0, baseDelayMs: 0, maxDelayMs: 0 },
    timeoutMs: 8000,
    circuitBreaker: { failureThreshold: 3, resetTimeoutMs: 15000 }
  },
  razorpayRead: {
    retry: { maxRetries: 2, baseDelayMs: 200, maxDelayMs: 2000 },
    timeoutMs: 3000,
    circuitBreaker: { failureThreshold: 3, resetTimeoutMs: 30000 }
  },
  razorpayMutation: {
    retry: { maxRetries: 0, baseDelayMs: 0, maxDelayMs: 0 },
    timeoutMs: 5000,
    circuitBreaker: { failureThreshold: 2, resetTimeoutMs: 30000 }
  }
};

export const LatencyWarningBudgets = {
  http: 300,
  firestoreRead: 100,
  firestoreWrite: 150,
  razorpay: 500
};

export interface RateLimitPolicy {
  maxRequests: number;
  windowMs: number; // TTL in milliseconds
  fallbackMode: 'fail_open' | 'fail_closed';
}

export const RateLimitPolicies: Record<string, RateLimitPolicy> = {
  ADMIN_API: { maxRequests: 60, windowMs: 60000, fallbackMode: 'fail_closed' }, // 60/min
  ORDER_CREATION: { maxRequests: 5, windowMs: 60000, fallbackMode: 'fail_closed' }, // 5/min to prevent transaction flooding
  TRANSFER_REQUEST: { maxRequests: 3, windowMs: 3600000, fallbackMode: 'fail_closed' }, // 3/hour to prevent locking abuse
  TRANSFER_REQUEST_HARD: { maxRequests: 10, windowMs: 86400000, fallbackMode: 'fail_closed' }, // 10/day hard limit for DB writes
  PUBLIC_API: { maxRequests: 100, windowMs: 60000, fallbackMode: 'fail_open' } // Global fallback
};
