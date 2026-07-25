export type LogLevel = 'TRACE' | 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';

export interface RequestContext {
  readonly traceId: string;
  readonly logger: LoggerService;
  readonly telemetry: TelemetryService;
  readonly execCtx?: ExecutionContext;
}

export class TelemetryService {
  // Sampling policy: Emits 100% of metrics currently. Future scaling decisions belong here.
  constructor(private traceId: string, private defaultTags: Record<string, string> = {}) {}

  private emit(type: 'metric' | 'counter', name: string, value: number, tags?: Record<string, string>) {
    try {
      const payload = {
        type,
        timestamp: new Date().toISOString(),
        traceId: this.traceId,
        name,
        value,
        tags: { ...this.defaultTags, ...tags }
      };
      // Emitted as standard JSON logs for provider-neutral forwarding
      console.log(JSON.stringify(payload));
    } catch (err) {
      // Telemetry is best-effort. Swallowing errors to prevent business disruption.
    }
  }

  metric(name: string, value: number, tags?: Record<string, string>) {
    this.emit('metric', name, value, tags);
  }

  counter(name: string, value: number = 1, tags?: Record<string, string>) {
    this.emit('counter', name, value, tags);
  }

  /**
   * High-order wrapper to measure duration and success/failure cleanly.
   * Guarantees measurement is emitted even if the operation throws.
   * Logs a warning if the operation duration exceeds the explicit latency budget.
   */
  async measure<T>(name: string, tags: Record<string, string>, operation: () => Promise<T>, latencyBudgetMs?: number): Promise<T> {
    let start = 0;
    try {
      start = performance.now();
    } catch (err) {
      // Ignore start time failure
    }
    
    let status = 'success';
    try {
      return await operation();
    } catch (error) {
      status = 'failure';
      throw error;
    } finally {
      try {
        const duration = performance.now() - start;
        this.metric(name, duration, { ...tags, status });

        if (latencyBudgetMs && duration > latencyBudgetMs) {
          // Log explicitly tied to telemetry, without breaking execution flow
          console.warn(JSON.stringify({
            level: 'WARN',
            timestamp: new Date().toISOString(),
            traceId: this.traceId,
            message: `BUDGET_EXCEEDED: [${name}] operation took ${duration.toFixed(2)}ms, exceeding budget of ${latencyBudgetMs}ms.`,
            tags: { ...tags, status }
          }));
        }
      } catch (telemetryErr) {
        // Swallowing errors to ensure business continuity
      }
    }
  }
}


export class LoggerService {
  constructor(private traceId: string, private defaultMetadata: Record<string, any> = {}) {}

  private emit(level: LogLevel, message: string, metadata?: Record<string, any>, error?: any) {
    const payload: any = {
      timestamp: new Date().toISOString(),
      level,
      traceId: this.traceId,
      message,
      ...this.defaultMetadata,
      ...metadata,
    };

    if (error) {
      payload.error = error instanceof Error ? error.stack || error.message : String(error);
    }

    const logString = JSON.stringify(payload);

    if (level === 'ERROR' || level === 'WARN') {
      console.error(logString);
    } else {
      console.log(logString);
    }
  }

  trace(message: string, metadata?: Record<string, any>) {
    this.emit('TRACE', message, metadata);
  }

  debug(message: string, metadata?: Record<string, any>) {
    this.emit('DEBUG', message, metadata);
  }

  info(message: string, metadata?: Record<string, any>) {
    this.emit('INFO', message, metadata);
  }

  warn(message: string, metadata?: Record<string, any>) {
    this.emit('WARN', message, metadata);
  }

  error(message: string, error?: any, metadata?: Record<string, any>) {
    this.emit('ERROR', message, metadata, error);
  }
}
