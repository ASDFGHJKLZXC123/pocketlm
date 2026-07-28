import repositoryCatalog from '../../models/catalog.json';
import { parseModelCatalog } from '../src/features/models/catalog';
import type { ReadyInstalledModel } from '../src/features/models/storage';
import {
  M4QualificationRunner,
  parseQualificationCollectorNonce,
  parseQualificationRcCommit,
  type QualificationArtifactSink,
  type QualificationNative,
  type QualificationSubscription,
} from '../src/features/qualification/runner';
import {
  BENCHMARK_ORDER,
  M4_PARAMS,
  M4_WORKLOAD_VERSION,
  UTF8_CORPUS,
} from '../src/features/qualification/spec';
import { encodeUtf8, isUnicodeScalarString, utf8Hex } from '../src/features/qualification/utf8';

const DONE_STATS = {
  prefillMs: 10,
  decodeMs: 20,
  promptTokens: 8,
  generatedTokens: 1,
  peakRssBytes: 123_456,
};
const COLLECTOR_NONCE = 'c'.repeat(32);

class FakeEvents {
  listener: ((event: unknown) => void) | null = null;
  removeCount = 0;

  subscribe = (listener: (event: unknown) => void): QualificationSubscription => {
    this.listener = listener;
    return {
      remove: () => {
        if (this.listener === listener) this.listener = null;
        this.removeCount += 1;
      },
    };
  };

  emit(event: unknown): void {
    this.listener?.(event);
  }
}

class FakeNative implements QualificationNative {
  loadCount = 0;
  unloadCount = 0;
  generateCount = 0;
  cancelCount = 0;
  gapFirstToken = false;
  private nextSessionId = 1;
  private readonly nextRequestBySession = new Map<number, number>();
  private readonly cancellationRequests = new Set<string>();

  constructor(private readonly events: FakeEvents) {}

  async loadModel(): Promise<number> {
    const sessionId = this.nextSessionId;
    this.nextSessionId += 1;
    this.nextRequestBySession.set(sessionId, 1);
    this.loadCount += 1;
    return sessionId;
  }

  async unloadModel(sessionId: number): Promise<void> {
    this.nextRequestBySession.delete(sessionId);
    this.unloadCount += 1;
  }

  async getDiagnostics() {
    return {
      requestedAccelerator: 'cpu' as const,
      selectedAccelerator: 'cpu' as const,
      contextSize: 2048,
      batchSize: 512,
      modelLayers: 24,
      offloadedLayers: 0,
      kqvOffloaded: false,
      peakRssBytes: 123_456,
    };
  }

  generate(
    sessionId: number,
    _messages: readonly { role: 'system' | 'user' | 'assistant'; content: string }[],
    params: {
      maxTokens: number;
      temperature: number;
      topK: number;
      topP: number;
      seed: number;
      nThreads: number;
    },
  ): number {
    const requestId = this.nextRequestBySession.get(sessionId);
    if (requestId === undefined) return -1;
    this.nextRequestBySession.set(sessionId, requestId + 1);
    this.generateCount += 1;
    const key = `${String(sessionId)}/${String(requestId)}`;
    const waitsForCancel = params.maxTokens === 256;
    if (waitsForCancel) this.cancellationRequests.add(key);
    const tokenIndex = this.gapFirstToken && this.generateCount === 1 ? 1 : 0;
    void Promise.resolve().then(() => {
      this.events.emit({
        type: 'token',
        sessionId,
        requestId,
        index: tokenIndex,
        tokenCount: 1,
        text: '✓',
      });
      if (!waitsForCancel) {
        this.events.emit({
          type: 'done',
          sessionId,
          requestId,
          reason: 'eos',
          stats: DONE_STATS,
        });
      }
    });
    return requestId;
  }

  cancel(sessionId: number, requestId: number): void {
    this.cancelCount += 1;
    const key = `${String(sessionId)}/${String(requestId)}`;
    if (!this.cancellationRequests.delete(key)) return;
    void Promise.resolve().then(() => {
      this.events.emit({
        type: 'done',
        sessionId,
        requestId,
        reason: 'cancelled',
        stats: DONE_STATS,
      });
    });
  }
}

function installedModel(): ReadyInstalledModel {
  const model = parseModelCatalog(repositoryCatalog).models[0];
  return {
    kind: 'ready',
    model,
    path: '/private/model.gguf',
    manifest: {
      installedAt: '2026-07-19T00:00:00.000Z',
    },
  } as unknown as ReadyInstalledModel;
}

function artifactSink(runId = 'm4-test-run'): QualificationArtifactSink & {
  writes: Map<string, unknown>;
  history: string[];
} {
  const writes = new Map<string, unknown>();
  const history: string[] = [];
  return {
    runId,
    writes,
    history,
    writeJson: async (filename, value) => {
      writes.set(filename, value);
      history.push(filename);
    },
  };
}

function testClock() {
  let monotonicMs = 0;
  return {
    monotonicMs: () => {
      monotonicMs += 0.25;
      return monotonicMs;
    },
    wallClockIso: () =>
      new Date(1_750_000_000_000 + Math.floor(monotonicMs)).toISOString(),
  };
}

function appProvenance(appCommit: string | null = 'a'.repeat(40)) {
  return {
    platform: 'ios',
    platformVersion: '17.5',
    buildMode: 'release' as const,
    appVersion: '1.0.0',
    jsEngine: 'Hermes',
    appCommit,
  };
}

describe('qualification workload', () => {
  it('freezes 25 UTF-8 sources x 4 instructions and a pass-major bench order', () => {
    expect(M4_WORKLOAD_VERSION).toBe('m4-workload-v2');
    expect(M4_PARAMS.benchmark.maxTokens).toBe(512);
    expect(M4_PARAMS.memory.maxTokens).toBe(32);
    expect(UTF8_CORPUS).toHaveLength(100);
    expect(new Set(UTF8_CORPUS.map((entry) => entry.id)).size).toBe(100);
    expect(
      UTF8_CORPUS.every(
        ({ prompt }) =>
          isUnicodeScalarString(prompt) &&
          /[\u{1F300}-\u{1FAFF}\u2600-\u27BF]/u.test(prompt) &&
          /[\u3400-\u9FFF\u3040-\u30FF]/u.test(prompt) &&
          /[\u0590-\u05FF\u0600-\u06FF]/u.test(prompt),
      ),
    ).toBe(true);
    expect(BENCHMARK_ORDER).toEqual([
      [0, 1, 2, 3, 4],
      [2, 3, 4, 0, 1],
      [4, 0, 1, 2, 3],
    ]);
  });

  it('preserves exact scalar UTF-8 bytes without platform encoders', () => {
    expect(encodeUtf8('A🙂中م')).toEqual([
      0x41,
      0xf0,
      0x9f,
      0x99,
      0x82,
      0xe4,
      0xb8,
      0xad,
      0xd9,
      0x85,
    ]);
    expect(utf8Hex('A🙂')).toBe('41f09f9982');
    expect(() => encodeUtf8('\ud800')).toThrow(/unpaired surrogate/);
  });

  it('accepts only strict 40-hex embedded RC commits', () => {
    expect(parseQualificationRcCommit(undefined)).toBeNull();
    expect(parseQualificationRcCommit(null)).toBeNull();
    expect(parseQualificationRcCommit('a'.repeat(39))).toBeNull();
    expect(parseQualificationRcCommit('/tmp/' + 'a'.repeat(40))).toBeNull();
    expect(parseQualificationRcCommit('G'.repeat(40))).toBeNull();
    expect(parseQualificationRcCommit('ABCDEF12'.repeat(5))).toBe(
      'abcdef12'.repeat(5),
    );
  });

  it('accepts only strict 32-hex collector nonces', () => {
    expect(parseQualificationCollectorNonce(undefined)).toBeNull();
    expect(parseQualificationCollectorNonce(null)).toBeNull();
    expect(parseQualificationCollectorNonce('c'.repeat(31))).toBeNull();
    expect(parseQualificationCollectorNonce('/tmp/' + 'c'.repeat(32))).toBeNull();
    expect(parseQualificationCollectorNonce('G'.repeat(32))).toBeNull();
    expect(parseQualificationCollectorNonce('ABCDEF12'.repeat(4))).toBe(
      'abcdef12'.repeat(4),
    );
  });

  it('runs the full matrix, checkpoints raw JSON, and writes COMPLETE last', async () => {
    const events = new FakeEvents();
    const native = new FakeNative(events);
    const sink = artifactSink();
    const runner = new M4QualificationRunner({
      native,
      subscribe: events.subscribe,
      clock: testClock(),
      delay: async () => undefined,
      lifecycleSettleMs: 0,
    });

    const summary = await runner.run({
      model: installedModel(),
      sink,
      suite: 'all',
      collectorNonce: COLLECTOR_NONCE,
      app: appProvenance(),
    });

    expect(summary.completedSuites).toEqual([
      'reproducibility',
      'utf8',
      'cancellation',
      'memory',
      'benchmark',
    ]);
    expect(native.loadCount).toBe(19);
    expect(native.unloadCount).toBe(19);
    expect(native.generateCount).toBe(153);
    expect(native.cancelCount).toBe(20);
    expect(events.removeCount).toBe(1);
    expect(sink.history.at(-1)).toBe('COMPLETE.json');
    expect(sink.writes.has('FAILED.json')).toBe(false);

    const reproducibility = sink.writes.get('reproducibility.json') as Record<
      string,
      unknown
    >;
    const utf8 = sink.writes.get('utf8.json') as Record<string, unknown>;
    const cancellation = sink.writes.get('cancellation.json') as Record<
      string,
      unknown
    >;
    const memory = sink.writes.get('memory.json') as Record<string, unknown>;
    const benchmark = sink.writes.get('benchmark.json') as Record<string, unknown>;
    const manifest = sink.writes.get('manifest.json') as Record<string, unknown>;

    expect(reproducibility['status']).toBe('passed');
    expect(utf8['completedGenerationCount']).toBe(100);
    expect(utf8['allOutputsValidUnicodeScalars']).toBe(true);
    expect(cancellation['completedTrialCount']).toBe(20);
    expect(cancellation['allTrialsStrictlyUnderLimit']).toBe(true);
    expect(cancellation['sameSessionAcrossAllTrials']).toBe(true);
    expect(memory['completedMeasuredCycles']).toBe(10);
    expect(memory['workloadVersion']).toBe('m4-workload-v2');
    expect((memory['params'] as Record<string, unknown>)['maxTokens']).toBe(32);
    expect(benchmark['completedMeasuredRunCount']).toBe(15);
    expect(benchmark['workloadVersion']).toBe('m4-workload-v2');
    expect((benchmark['params'] as Record<string, unknown>)['maxTokens']).toBe(512);
    expect(manifest['status']).toBe('complete');
    expect(manifest['workloadVersion']).toBe('m4-workload-v2');
    expect(manifest['selectedSuite']).toBe('all');
    expect(manifest['collectorNonce']).toBe(COLLECTOR_NONCE);
    const fixedParameters = manifest['fixedParameters'] as Record<
      string,
      Record<string, unknown>
    >;
    expect(fixedParameters['benchmark']['maxTokens']).toBe(512);
    expect(fixedParameters['memory']['maxTokens']).toBe(32);
    const complete = sink.writes.get('COMPLETE.json') as Record<string, unknown>;
    expect(complete['collectorNonce']).toBe(COLLECTOR_NONCE);
    expect(
      (manifest['model'] as Record<string, unknown>)['installedPath'],
    ).toBeUndefined();
    expect(manifest['sourceBinding']).toEqual({
      appCommit: 'a'.repeat(40),
      appCommitEmbedded: true,
      note: 'The 40-hex RC commit was embedded at JavaScript bundle build time.',
    });
  });

  it('runs an isolated memory-only workload with no timing contaminants', async () => {
    const events = new FakeEvents();
    const native = new FakeNative(events);
    const sink = artifactSink('m4-memory-only');
    const runner = new M4QualificationRunner({
      native,
      subscribe: events.subscribe,
      clock: testClock(),
      delay: async () => undefined,
      lifecycleSettleMs: 0,
    });

    const summary = await runner.run({
      model: installedModel(),
      sink,
      suite: 'memory',
      collectorNonce: null,
      app: appProvenance('/tmp/not-a-commit'),
    });

    expect(summary.completedSuites).toEqual(['memory']);
    expect(native.loadCount).toBe(11);
    expect(native.generateCount).toBe(11);
    expect(sink.writes.has('benchmark.json')).toBe(false);
    const manifest = sink.writes.get('manifest.json') as Record<string, unknown>;
    const memory = sink.writes.get('memory.json') as Record<string, unknown>;
    expect(manifest['workloadVersion']).toBe('m4-workload-v2');
    expect(manifest['selectedSuite']).toBe('memory');
    expect(manifest['selectedSuites']).toEqual(['memory']);
    expect(memory['workloadVersion']).toBe('m4-workload-v2');
    expect((memory['params'] as Record<string, unknown>)['maxTokens']).toBe(32);
    const sourceBinding = manifest['sourceBinding'] as Record<string, unknown>;
    expect(sourceBinding['appCommit']).toBeNull();
    expect(sourceBinding['appCommitEmbedded']).toBe(false);
    expect(
      (manifest['app'] as Record<string, unknown>)['appCommit'],
    ).toBeNull();
    expect(sink.history.at(-1)).toBe('COMPLETE.json');
  });

  it('writes FAILED and never COMPLETE after a protocol fault', async () => {
    const events = new FakeEvents();
    const native = new FakeNative(events);
    native.gapFirstToken = true;
    const sink = artifactSink('m4-failed');
    const runner = new M4QualificationRunner({
      native,
      subscribe: events.subscribe,
      clock: testClock(),
      delay: async () => undefined,
      lifecycleSettleMs: 0,
    });

    let failure: unknown;
    try {
      await runner.run({
        model: installedModel(),
        sink,
        suite: 'all',
        collectorNonce: COLLECTOR_NONCE,
        app: appProvenance(),
      });
    } catch (error: unknown) {
      failure = error;
    }
    expect(failure).toBeTruthy();
    expect(failure instanceof Error ? failure.message : String(failure)).toMatch(
      /Non-contiguous token index/,
    );

    expect(sink.writes.has('FAILED.json')).toBe(true);
    expect(sink.writes.has('COMPLETE.json')).toBe(false);
    expect(sink.history.at(-1)).toBe('FAILED.json');
    const failureArtifact = sink.writes.get('FAILED.json') as Record<
      string,
      unknown
    >;
    expect(failureArtifact['completedSuites']).toEqual([]);
    expect(failureArtifact['collectorNonce']).toBe(COLLECTOR_NONCE);
    expect(events.removeCount).toBe(1);
  });
});
