import { describe, it, expect, beforeEach } from 'vitest';
import { resetTestEnv, getMockEnv, mockFirestore, TestClock } from '../setup';
import { handleRazorpayWebhook } from '../../src/webhooks';
import { handleCreateOrder } from '../../src/routes/orders';
import { handleCancelTransfer } from '../../src/routes/transfers';
import { writeFileSync } from 'fs';
import { join } from 'path';
import { vi } from 'vitest';

vi.mock('../../src/authGuard', () => ({
  authenticateRequest: vi.fn(async (ctx: any, request: any) => {
    return {
      identity: {
        customerId: 'cust_perf',
        installationId: 'inst_perf',
        hardwareId: 'hw_perf',
        uid: 'firebase_perf',
        platform: 'android',
        appVersion: '1.0'
      }
    };
  }),
  createErrorResponse: vi.fn((status: number, code: string, message: string) => {
    return new Response(JSON.stringify({ error: { code, message } }), { status });
  })
}));

const mockCtx = {
  traceId: 'benchmark-trace',
  logger: { trace: () => {}, debug: () => {}, info: () => {}, warn: () => {}, error: () => {} },
  telemetry: { measure: async (name: string, tags: any, fn: any) => fn() }
} as any;

describe('Phase 7A: Performance Baselines', () => {
  let env: any;
  const metrics: Array<{ name: string; latencyMs: number; reads: number; writes: number }> = [];

  beforeEach(() => {
    resetTestEnv();
    env = getMockEnv();
    mockFirestore.getDocument.mockClear();
    mockFirestore.queryCollection.mockClear();
    mockFirestore.commitAtomicWrites.mockClear();
  });

  const recordMetric = (name: string, durationMs: number) => {
    const reads = mockFirestore.getDocument.mock.calls.length + mockFirestore.queryCollection.mock.calls.length;
    const writes = mockFirestore.commitAtomicWrites.mock.calls.length;
    metrics.push({ name, latencyMs: durationMs, reads, writes });
  };

  it('measures Webhook Payment Settlement (Cold & Warm)', async () => {
    const customerId = 'cust_perf';
    const installationId = 'inst_perf';
    const razorpayOrderId = 'order_perf';
    mockFirestore._db.set(`installations/${installationId}`, { installationId, customerId, status: 'ACTIVE' });
    mockFirestore._db.set(`payments/${razorpayOrderId}`, { paymentId: razorpayOrderId, razorpayOrderId, installationId, customerId, planId: 'PRO_YEARLY', status: 'INITIATED', createdAtEpochMs: TestClock.now() });

    const req = new Request('https://api.vendsoft.com/webhooks/razorpay', {
      method: 'POST',
      headers: { 'x-razorpay-signature': 'valid_webhook_sig', 'Content-Type': 'application/json' },
      body: JSON.stringify({ event: 'payment.captured', payload: { payment: { entity: { id: 'pay_perf', order_id: razorpayOrderId } } } })
    });

    // Isolate the HTTP layer benchmark from the background consumer execution
    env.WEBHOOK_QUEUE.send = vi.fn(async () => {});

    const start = process.hrtime.bigint();
    await handleRazorpayWebhook(mockCtx, req, env);
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;

    recordMetric('Webhook Settlement', durationMs);
    expect(durationMs).toBeLessThan(200);
  });

  it('measures Order Creation', async () => {
    const req = new Request('https://api.vendsoft.com/v1/orders/create', {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer valid_token',
        'x-hardware-id': 'hw_perf',
        'x-installation-uuid': 'inst_perf',
        'x-app-version': '1.0',
        'x-platform': 'android',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ planId: 'PRO_YEARLY' })
    });

    const start = process.hrtime.bigint();
    const response = await handleCreateOrder(mockCtx, req, env);
    const durationMs = Number(process.hrtime.bigint() - start) / 1e6;

    expect(response.status).toBe(201);
    recordMetric('Order Creation', durationMs);
  });

  it('generates PERFORMANCE_DASHBOARD.md', () => {
    let md = `# Phase 7 Performance Dashboard (Baseline)\n\n`;
    md += `| Operation | Latency (ms) | Firestore Reads | Atomic Commits |\n`;
    md += `| :--- | ---: | ---: | ---: |\n`;
    for (const m of metrics) {
      md += `| ${m.name} | ${m.latencyMs.toFixed(2)} ms | ${m.reads} | ${m.writes} |\n`;
    }
    md += `\n*Note: Simulated environment utilizing FakeTimers and in-memory Map mock.*`;
    
    writeFileSync(join(__dirname, '../../../../docs/PERFORMANCE_DASHBOARD.md'), md);
  });
});
