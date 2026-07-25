export class TimeoutError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'TimeoutError';
  }
}

/**
 * Executes a Promise-based operation with an enforced strict timeout.
 * If the operation supports cancellation, it should consume the provided AbortSignal.
 */
export async function executeWithTimeout<T>(
  timeoutMs: number,
  operation: (signal: AbortSignal) => Promise<T>
): Promise<T> {
  if (timeoutMs <= 0) {
    throw new Error('Timeout must be greater than 0 ms');
  }

  const controller = new AbortController();
  const timeoutId = setTimeout(() => {
    controller.abort(new TimeoutError(`Operation timed out after ${timeoutMs}ms`));
  }, timeoutMs);

  try {
    const result = await operation(controller.signal);
    return result;
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') {
      throw new TimeoutError(`Operation timed out after ${timeoutMs}ms`);
    }
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}
