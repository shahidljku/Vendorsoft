import { RequestContext } from './logger';
import { Env } from '../types';
import { getDocument } from './firestore';

export type HealthState = 'healthy' | 'degraded' | 'unhealthy';

export interface DiagnosticResponse {
  status: HealthState;
  version: string;
  release: {
    commit: string;
    buildTimestamp: string;
  };
  checks: {
    configuration: HealthState;
    firestore: HealthState | string;
    razorpay: HealthState | string;
    rsa: HealthState | string;
    [key: string]: HealthState | string;
  };
  telemetry: {
    enabled: boolean;
    registryVersion: number;
  };
}

export class HealthService {
  /**
   * Shallow public health check.
   * Returns a basic acknowledgment that the worker is receiving HTTP traffic.
   */
  static getShallowHealth(): { status: 'ok' } {
    return { status: 'ok' };
  }

  /**
   * Deep diagnostic check for administrative monitoring.
   * Evaluates configuration (Level 1), runtime state (Level 2), and executes optional probes (Level 3).
   * Strictly forbids exposing environment variable values.
   */
  static async getDiagnostics(ctx: RequestContext, env: Env, probe?: string): Promise<DiagnosticResponse> {
    const checks: Record<string, HealthState | string> = {};
    let overallStatus: HealthState = 'healthy';

    // LEVEL 1: Configuration (Immediate, No Network)
    const hasFirestore = !!env.FIRESTORE_SA_KEY;
    const hasRazorpay = !!(env.RAZORPAY_KEY_ID && env.RAZORPAY_KEY_SECRET && env.RAZORPAY_WEBHOOK_SECRET);
    const hasRSA = !!env.RSA_PRIVATE_KEY;

    checks.configuration = (hasFirestore && hasRazorpay && hasRSA) ? 'healthy' : 'unhealthy';
    
    // Explicitly redact secrets - report readiness state only
    checks.firestore = hasFirestore ? 'configured' : 'missing';
    checks.razorpay = hasRazorpay ? 'configured' : 'missing';
    checks.rsa = hasRSA ? 'configured' : 'missing';

    if (!hasFirestore || !hasRazorpay || !hasRSA) {
      overallStatus = 'unhealthy'; // Missing critical infrastructure configuration
    }

    // LEVEL 2: Runtime State
    const version = env.WORKER_VERSION || 'unknown';

    // LEVEL 3: Optional Active Probes
    if (probe === 'firestore') {
      if (hasFirestore) {
        try {
          // Perform a lightweight active network read.
          // Expecting null is fine; a successful 404 implies network and auth succeeded.
          await getDocument(ctx, env, 'system', 'health_ping');
          checks['probe.firestore'] = 'healthy';
        } catch (err: any) {
          ctx.logger.error('Active Firestore probe failed', err);
          checks['probe.firestore'] = 'unhealthy';
          if (overallStatus === 'healthy') overallStatus = 'degraded';
        }
      } else {
        checks['probe.firestore'] = 'unhealthy';
      }
    }

    // Assemble stable response payload
    return {
      status: overallStatus,
      version,
      release: {
        commit: env.GIT_COMMIT || 'unknown',
        buildTimestamp: env.BUILD_TIMESTAMP || 'unknown'
      },
      checks: checks as any,
      telemetry: {
        enabled: true,
        registryVersion: 1
      }
    };
  }
}
