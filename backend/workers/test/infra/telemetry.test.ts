import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { TelemetryService } from '../../src/services/logger';

describe('TelemetryService', () => {
  let telemetry: TelemetryService;
  let consoleSpy: any;

  beforeEach(() => {
    telemetry = new TelemetryService('test-trace', { globalTag: 'true' });
    consoleSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('emits telemetry and returns result on successful operation', async () => {
    const result = await telemetry.measure('test.duration', { op: 'test' }, async () => {
      return 'business_result';
    });

    expect(result).toBe('business_result');
    expect(consoleSpy).toHaveBeenCalledTimes(1);
    
    const loggedStr = consoleSpy.mock.calls[0][0];
    const loggedObj = JSON.parse(loggedStr);
    
    expect(loggedObj.type).toBe('metric');
    expect(loggedObj.name).toBe('test.duration');
    expect(loggedObj.traceId).toBe('test-trace');
    expect(loggedObj.tags.op).toBe('test');
    expect(loggedObj.tags.status).toBe('success');
    expect(typeof loggedObj.value).toBe('number');
  });

  it('emits failure status and rethrows on business logic exception', async () => {
    const error = new Error('Business Exception');
    
    await expect(
      telemetry.measure('test.duration', { op: 'test' }, async () => {
        throw error;
      })
    ).rejects.toThrow('Business Exception');

    expect(consoleSpy).toHaveBeenCalledTimes(1);
    
    const loggedStr = consoleSpy.mock.calls[0][0];
    const loggedObj = JSON.parse(loggedStr);
    
    expect(loggedObj.tags.status).toBe('failure');
  });

  it('swallows internal telemetry errors and preserves successful business logic', async () => {
    // Force an error inside metric generation
    vi.spyOn(performance, 'now').mockImplementationOnce(() => {
      throw new Error('Internal Telemetry Crash');
    });

    const result = await telemetry.measure('test.duration', { op: 'test' }, async () => {
      return 'safe_result';
    });

    // The business result is perfectly preserved despite the telemetry crash
    expect(result).toBe('safe_result');
  });
});
