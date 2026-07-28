import type {
  BackendDiagnostics,
  GenerationParams,
  NativeChatMessage,
  Spec as NativePocketLMSpec,
} from '../../lib/NativePocketLM';
import { parseInferenceEvent } from '../inference/coordinator';
import type { GenerationStats, InferenceEvent } from '../inference/types';
import type { ReadyInstalledModel } from '../models/storage';
import {
  BENCHMARK_ORDER,
  BENCHMARK_PROMPTS,
  CANCELLATION_PROMPT,
  M4_PARAMS,
  M4_SESSION_CONFIG,
  M4_WORKLOAD_VERSION,
  MEMORY_PROMPT,
  REPRODUCIBILITY_PROMPT,
  UTF8_CORPUS,
  singleUserMessage,
} from './spec';
import { encodeUtf8, isUnicodeScalarString, unicodeScalarCount } from './utf8';

const MAX_INT32 = 2_147_483_647;
const CANCELLATION_LIMIT_MS = 200;
const GENERATION_TIMEOUT_MS = 180_000;

export type QualificationSuite = 'all' | 'memory';
export type QualificationPhase =
  | 'preparing'
  | 'reproducibility'
  | 'utf8'
  | 'cancellation'
  | 'memory'
  | 'benchmark'
  | 'complete'
  | 'failed';

export type QualificationProgress = {
  phase: QualificationPhase;
  completed: number;
  total: number;
  detail: string;
};

export type QualificationClock = {
  monotonicMs: () => number;
  wallClockIso: () => string;
};

export type QualificationArtifactSink = {
  readonly runId: string;
  writeJson: (filename: string, value: unknown) => Promise<void>;
};

export type QualificationNative = Pick<
  NativePocketLMSpec,
  'loadModel' | 'unloadModel' | 'generate' | 'cancel' | 'getDiagnostics'
>;

export type QualificationSubscription = { remove: () => void };

export type QualificationRunnerDependencies = {
  native: QualificationNative;
  subscribe: (
    listener: (event: unknown) => void,
  ) => QualificationSubscription;
  clock?: QualificationClock;
  delay?: (milliseconds: number) => Promise<void>;
  generationTimeoutMs?: number;
  lifecycleSettleMs?: number;
  onProgress?: (progress: QualificationProgress) => void;
};

export type AppObservableProvenance = {
  platform: string;
  platformVersion: string;
  buildMode: 'debug' | 'release';
  appVersion: string | null;
  jsEngine: string | null;
  appCommit: string | null;
};

export type RunQualificationInput = {
  model: ReadyInstalledModel;
  sink: QualificationArtifactSink;
  suite: QualificationSuite;
  collectorNonce: string | null;
  app: AppObservableProvenance;
};

type Timestamp = {
  wallClock: string;
  monotonicMs: number;
};

type RawTokenEvent = Timestamp & {
  type: 'token';
  sessionId: number;
  requestId: number;
  index: number;
  tokenCount: number;
  text: string;
};

type RawDoneEvent = Timestamp & {
  type: 'done';
  sessionId: number;
  requestId: number;
  reason: Extract<InferenceEvent, { type: 'done' }>['reason'];
  stats: GenerationStats;
};

type RawErrorEvent = Timestamp & {
  type: 'error';
  sessionId: number;
  requestId: number;
  code: Extract<InferenceEvent, { type: 'error' }>['code'];
  message: string;
};

type RawInferenceEvent = RawTokenEvent | RawDoneEvent | RawErrorEvent;

export type GenerationCapture = {
  sessionId: number;
  requestId: number;
  messages: readonly NativeChatMessage[];
  params: GenerationParams;
  generateInvoked: Timestamp;
  requestAccepted: Timestamp;
  firstTokenDelivered: Timestamp | null;
  terminalDelivered: Timestamp;
  terminal: RawDoneEvent;
  rawEvents: readonly RawInferenceEvent[];
  output: string;
  outputUtf8Hex: string;
  outputUtf8ByteCount: number;
  outputUnicodeScalarCount: number;
  unicodeScalarValid: true;
  tokenIndicesContiguous: true;
  terminalCount: 1;
  postTerminalEventCount: number;
  cancellation: null | {
    streamObserved: Timestamp;
    cancelInvoked: Timestamp;
    cancelReturned: Timestamp;
    terminalDelivered: Timestamp;
    latencyMs: number;
  };
};

type PendingGeneration = {
  sessionId: number;
  requestId: number;
  messages: readonly NativeChatMessage[];
  params: GenerationParams;
  generateInvoked: Timestamp;
  requestAccepted: Timestamp;
  firstTokenDelivered: Timestamp | null;
  expectedTokenIndex: number;
  outputParts: string[];
  rawEvents: RawInferenceEvent[];
  terminalCount: number;
  postTerminalEventCount: number;
  cancelOnFirstToken: boolean;
  cancellation: GenerationCapture['cancellation'];
  protocolError: Error | null;
  timeout: ReturnType<typeof setTimeout>;
  resolve: (capture: GenerationCapture) => void;
  reject: (error: Error) => void;
};

type SessionRecord = {
  sessionId: number;
  loaded: Timestamp;
  diagnostics: BackendDiagnostics;
};

export type QualificationRunSummary = {
  runId: string;
  suite: QualificationSuite;
  collectorNonce: string | null;
  completedSuites: readonly string[];
  startedAt: string;
  completedAt: string;
};

function defaultClock(): QualificationClock {
  return {
    monotonicMs: () => {
      const timer = (
        globalThis as { performance?: { now: () => number } }
      ).performance;
      return timer === undefined ? Date.now() : timer.now();
    },
    wallClockIso: () => new Date().toISOString(),
  };
}

function defaultDelay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function safeErrorMessage(error: unknown): string {
  if (error instanceof Error && error.message.length > 0) return error.message;
  return String(error);
}

function artifactErrorMessage(error: unknown, modelPath: string): string {
  return safeErrorMessage(error)
    .split(modelPath)
    .join('[installed-model-path]')
    .replace(/file:\/\/\/[^\s]+/g, '[redacted-local-file-uri]');
}

export function parseQualificationRcCommit(value: unknown): string | null {
  return typeof value === 'string' && /^[0-9a-f]{40}$/i.test(value)
    ? value.toLowerCase()
    : null;
}

export function parseQualificationCollectorNonce(value: unknown): string | null {
  return typeof value === 'string' && /^[0-9a-f]{32}$/i.test(value)
    ? value.toLowerCase()
    : null;
}

function isPositiveInt32(value: number): boolean {
  return Number.isInteger(value) && value > 0 && value <= MAX_INT32;
}

function cloneStats(stats: GenerationStats): GenerationStats {
  return {
    prefillMs: stats.prefillMs,
    decodeMs: stats.decodeMs,
    promptTokens: stats.promptTokens,
    generatedTokens: stats.generatedTokens,
    peakRssBytes: stats.peakRssBytes,
  };
}

function cloneDiagnostics(value: BackendDiagnostics): BackendDiagnostics {
  return {
    requestedAccelerator: value.requestedAccelerator,
    selectedAccelerator: value.selectedAccelerator,
    contextSize: value.contextSize,
    batchSize: value.batchSize,
    modelLayers: value.modelLayers,
    offloadedLayers: value.offloadedLayers,
    kqvOffloaded: value.kqvOffloaded,
    peakRssBytes: value.peakRssBytes,
  };
}

function frozenParams(value: GenerationParams): GenerationParams {
  return {
    maxTokens: value.maxTokens,
    temperature: value.temperature,
    topK: value.topK,
    topP: value.topP,
    seed: value.seed,
    nThreads: value.nThreads,
  };
}

class NativeGenerationDriver {
  private readonly native: QualificationNative;
  private readonly clock: QualificationClock;
  private readonly generationTimeoutMs: number;
  private readonly subscription: QualificationSubscription;
  private active: PendingGeneration | null = null;
  private readonly completed = new Map<string, GenerationCapture>();
  private ignoredForeignEventCount = 0;
  private invalidEventCount = 0;
  private postTerminalEventCount = 0;

  constructor(
    native: QualificationNative,
    subscribe: QualificationRunnerDependencies['subscribe'],
    clock: QualificationClock,
    generationTimeoutMs: number,
  ) {
    this.native = native;
    this.clock = clock;
    this.generationTimeoutMs = generationTimeoutMs;
    this.subscription = subscribe((raw) => this.receive(raw));
  }

  get eventDiagnostics(): {
    ignoredForeignEventCount: number;
    invalidEventCount: number;
    postTerminalEventCount: number;
  } {
    return {
      ignoredForeignEventCount: this.ignoredForeignEventCount,
      invalidEventCount: this.invalidEventCount,
      postTerminalEventCount: this.postTerminalEventCount,
    };
  }

  close(): void {
    this.subscription.remove();
  }

  generate(
    sessionId: number,
    messages: readonly NativeChatMessage[],
    params: GenerationParams,
    options: { cancelOnFirstToken?: boolean } = {},
  ): Promise<GenerationCapture> {
    if (this.active !== null) {
      return Promise.reject(
        new Error('Qualification attempted overlapping native generations.'),
      );
    }

    const copiedMessages = messages.map((message) => ({
      role: message.role,
      content: `${message.content}`,
    }));
    const copiedParams = frozenParams(params);
    const generateInvoked = this.stamp();
    let requestId: number;
    try {
      requestId = this.native.generate(
        sessionId,
        copiedMessages,
        copiedParams,
      );
    } catch (error: unknown) {
      return Promise.reject(
        new Error(`Native generate threw: ${safeErrorMessage(error)}`),
      );
    }
    const requestAccepted = this.stamp();
    if (!isPositiveInt32(requestId)) {
      return Promise.reject(
        new Error(
          `Native generate rejected qualification request with ${String(requestId)}.`,
        ),
      );
    }

    return new Promise<GenerationCapture>((resolve, reject) => {
      const pending: PendingGeneration = {
        sessionId,
        requestId,
        messages: copiedMessages,
        params: copiedParams,
        generateInvoked,
        requestAccepted,
        firstTokenDelivered: null,
        expectedTokenIndex: 0,
        outputParts: [],
        rawEvents: [],
        terminalCount: 0,
        postTerminalEventCount: 0,
        cancelOnFirstToken: options.cancelOnFirstToken === true,
        cancellation: null,
        protocolError: null,
        timeout: setTimeout(() => {
          if (this.active !== pending) return;
          this.active = null;
          try {
            this.native.cancel(pending.sessionId, pending.requestId);
          } catch {
            // Session cleanup is still awaited by the owning runner.
          }
          reject(
            new Error(
              `Generation ${String(pending.sessionId)}/${String(pending.requestId)} ` +
                `did not deliver a terminal within ${String(this.generationTimeoutMs)} ms.`,
            ),
          );
        }, this.generationTimeoutMs),
        resolve,
        reject,
      };
      this.active = pending;
    });
  }

  private receive(raw: unknown): void {
    // Capture delivery time before parsing/copying so cancellation latency ends
    // at the matching DONE delivery boundary, not after JavaScript processing.
    const delivered = this.stamp();
    const event = parseInferenceEvent(raw);
    if (event === null) {
      this.invalidEventCount += 1;
      if (this.active !== null && this.active.protocolError === null) {
        this.active.protocolError = new Error(
          'Native delivered an invalid inference event during qualification.',
        );
        this.cancelActiveAfterProtocolFault();
      }
      return;
    }

    const key = this.key(event.sessionId, event.requestId);
    const pending = this.active;
    if (
      pending === null ||
      pending.sessionId !== event.sessionId ||
      pending.requestId !== event.requestId
    ) {
      const completed = this.completed.get(key);
      if (completed !== undefined) {
        completed.postTerminalEventCount += 1;
        this.postTerminalEventCount += 1;
      }
      else this.ignoredForeignEventCount += 1;
      return;
    }

    if (event.type === 'token') {
      this.receiveToken(pending, event, delivered);
      return;
    }
    if (event.type === 'done') {
      this.receiveDone(pending, event, delivered);
      return;
    }
    this.receiveError(pending, event, delivered);
  }

  private receiveToken(
    pending: PendingGeneration,
    event: Extract<InferenceEvent, { type: 'token' }>,
    delivered: Timestamp,
  ): void {
    const copied: RawTokenEvent = {
      ...delivered,
      type: 'token',
      sessionId: event.sessionId,
      requestId: event.requestId,
      index: event.index,
      tokenCount: event.tokenCount,
      text: `${event.text}`,
    };
    pending.rawEvents.push(copied);

    if (event.index !== pending.expectedTokenIndex) {
      if (pending.protocolError === null) {
        pending.protocolError = new Error(
          `Non-contiguous token index: expected ${String(
            pending.expectedTokenIndex,
          )}, received ${String(event.index)}.`,
        );
        this.cancelActiveAfterProtocolFault();
      }
      return;
    }

    pending.expectedTokenIndex += event.tokenCount;
    pending.outputParts.push(`${event.text}`);
    if (pending.firstTokenDelivered === null) {
      pending.firstTokenDelivered = delivered;
    }

    if (pending.cancelOnFirstToken && pending.cancellation === null) {
      // The monotonic timestamp is deliberately the last operation before the
      // cancel invocation. DONE delivery is timestamped on listener entry.
      const streamObserved = pending.firstTokenDelivered;
      const invokedWallClock = this.clock.wallClockIso();
      try {
        const invokedMonotonicMs = this.clock.monotonicMs();
        this.native.cancel(pending.sessionId, pending.requestId);
        const cancelReturned = this.stamp();
        pending.cancellation = {
          streamObserved,
          cancelInvoked: {
            wallClock: invokedWallClock,
            monotonicMs: invokedMonotonicMs,
          },
          cancelReturned,
          terminalDelivered: cancelReturned,
          latencyMs: -1,
        };
      } catch (error: unknown) {
        pending.protocolError = new Error(
          `Native cancel threw: ${safeErrorMessage(error)}`,
        );
        return;
      }
    }
  }

  private receiveDone(
    pending: PendingGeneration,
    event: Extract<InferenceEvent, { type: 'done' }>,
    delivered: Timestamp,
  ): void {
    pending.terminalCount += 1;
    const copied: RawDoneEvent = {
      ...delivered,
      type: 'done',
      sessionId: event.sessionId,
      requestId: event.requestId,
      reason: event.reason,
      stats: cloneStats(event.stats),
    };
    pending.rawEvents.push(copied);

    if (pending.cancelOnFirstToken) {
      if (pending.cancellation === null) {
        pending.protocolError ??= new Error(
          'Cancellation trial reached terminal before observable streaming.',
        );
      } else {
        pending.cancellation.terminalDelivered = delivered;
        pending.cancellation.latencyMs =
          delivered.monotonicMs - pending.cancellation.cancelInvoked.monotonicMs;
      }
      if (event.reason !== 'cancelled') {
        pending.protocolError ??= new Error(
          `Cancellation trial ended with ${event.reason}, not cancelled.`,
        );
      }
    }
    if (pending.terminalCount !== 1) {
      pending.protocolError ??= new Error(
        `Request delivered ${String(pending.terminalCount)} terminal events.`,
      );
    }

    const output = pending.outputParts.join('');
    let bytes: readonly number[] = [];
    try {
      bytes = encodeUtf8(output);
    } catch (error: unknown) {
      pending.protocolError ??= new Error(safeErrorMessage(error));
    }
    const capture: GenerationCapture = {
      sessionId: pending.sessionId,
      requestId: pending.requestId,
      messages: pending.messages,
      params: pending.params,
      generateInvoked: pending.generateInvoked,
      requestAccepted: pending.requestAccepted,
      firstTokenDelivered: pending.firstTokenDelivered,
      terminalDelivered: delivered,
      terminal: copied,
      rawEvents: pending.rawEvents,
      output,
      outputUtf8Hex: bytes
        .map((byte) => byte.toString(16).padStart(2, '0'))
        .join(''),
      outputUtf8ByteCount: bytes.length,
      outputUnicodeScalarCount: unicodeScalarCount(output),
      unicodeScalarValid: true,
      tokenIndicesContiguous: true,
      terminalCount: 1,
      postTerminalEventCount: pending.postTerminalEventCount,
      cancellation: pending.cancellation,
    };

    clearTimeout(pending.timeout);
    this.active = null;
    this.completed.set(this.key(pending.sessionId, pending.requestId), capture);
    if (pending.protocolError !== null) pending.reject(pending.protocolError);
    else pending.resolve(capture);
  }

  private receiveError(
    pending: PendingGeneration,
    event: Extract<InferenceEvent, { type: 'error' }>,
    delivered: Timestamp,
  ): void {
    const copied: RawErrorEvent = {
      ...delivered,
      type: 'error',
      sessionId: event.sessionId,
      requestId: event.requestId,
      code: event.code,
      message: `${event.message}`,
    };
    pending.rawEvents.push(copied);
    clearTimeout(pending.timeout);
    this.active = null;
    pending.reject(
      new Error(`Native ${event.code} terminal: ${event.message}`),
    );
  }

  private cancelActiveAfterProtocolFault(): void {
    if (this.active === null) return;
    try {
      this.native.cancel(this.active.sessionId, this.active.requestId);
    } catch {
      // Awaited session unload remains the final ownership fence.
    }
  }

  private stamp(): Timestamp {
    return {
      wallClock: this.clock.wallClockIso(),
      monotonicMs: this.clock.monotonicMs(),
    };
  }

  private key(sessionId: number, requestId: number): string {
    return `${String(sessionId)}/${String(requestId)}`;
  }
}

export class M4QualificationRunner {
  private readonly native: QualificationNative;
  private readonly subscribe: QualificationRunnerDependencies['subscribe'];
  private readonly clock: QualificationClock;
  private readonly delay: (milliseconds: number) => Promise<void>;
  private readonly generationTimeoutMs: number;
  private readonly lifecycleSettleMs: number;
  private readonly onProgress: (progress: QualificationProgress) => void;

  constructor(dependencies: QualificationRunnerDependencies) {
    this.native = dependencies.native;
    this.subscribe = dependencies.subscribe;
    this.clock = dependencies.clock ?? defaultClock();
    this.delay = dependencies.delay ?? defaultDelay;
    this.generationTimeoutMs =
      dependencies.generationTimeoutMs ?? GENERATION_TIMEOUT_MS;
    this.lifecycleSettleMs = dependencies.lifecycleSettleMs ?? 10_000;
    this.onProgress = dependencies.onProgress ?? (() => undefined);
  }

  async run(input: RunQualificationInput): Promise<QualificationRunSummary> {
    const startedAt = this.clock.wallClockIso();
    const collectorNonce = parseQualificationCollectorNonce(input.collectorNonce);
    const completedSuites: string[] = [];
    const manifest = this.makeManifest(
      input,
      collectorNonce,
      startedAt,
      completedSuites,
    );
    let driver: NativeGenerationDriver | null = null;

    try {
      driver = new NativeGenerationDriver(
        this.native,
        this.subscribe,
        this.clock,
        this.generationTimeoutMs,
      );
      this.progress('preparing', 0, 1, `Preparing ${input.suite} suite`);
      await input.sink.writeJson('manifest.json', manifest);
      if (input.suite === 'all') {
        await this.runReproducibility(input, driver);
        completedSuites.push('reproducibility');
        await this.checkpointManifest(input, manifest, completedSuites);

        await this.runUtf8(input, driver);
        completedSuites.push('utf8');
        await this.checkpointManifest(input, manifest, completedSuites);

        await this.runCancellation(input, driver);
        completedSuites.push('cancellation');
        await this.checkpointManifest(input, manifest, completedSuites);

        await this.runMemory(input, driver);
        completedSuites.push('memory');
        await this.checkpointManifest(input, manifest, completedSuites);

        await this.runBenchmark(input, driver);
        completedSuites.push('benchmark');
        await this.checkpointManifest(input, manifest, completedSuites);
      } else {
        await this.runMemory(input, driver);
        completedSuites.push('memory');
        await this.checkpointManifest(input, manifest, completedSuites);
      }

      // Allow already-enqueued bridge delivery to expose any post-terminal
      // contract fault before the success sentinel is written.
      await this.delay(0);
      const eventDiagnostics = driver.eventDiagnostics;
      if (
        eventDiagnostics.invalidEventCount !== 0 ||
        eventDiagnostics.ignoredForeignEventCount !== 0 ||
        eventDiagnostics.postTerminalEventCount !== 0
      ) {
        throw new Error(
          'The qualification event channel was not quiescent and exclusive.',
        );
      }
      driver.close();
      driver = null;
      const completedAt = this.clock.wallClockIso();
      const finalManifest = {
        ...manifest,
        status: 'complete',
        completedAt,
        completedSuites: [...completedSuites],
        eventDiagnostics,
      };
      await input.sink.writeJson('manifest.json', finalManifest);
      await input.sink.writeJson('COMPLETE.json', {
        schemaVersion: 1,
        runId: input.sink.runId,
        suite: input.suite,
        collectorNonce,
        completedAt,
        completedSuites: [...completedSuites],
      });
      this.progress('complete', completedSuites.length, completedSuites.length, 'Complete');
      return {
        runId: input.sink.runId,
        suite: input.suite,
        collectorNonce,
        completedSuites: [...completedSuites],
        startedAt,
        completedAt,
      };
    } catch (error: unknown) {
      const failedAt = this.clock.wallClockIso();
      const message = artifactErrorMessage(error, input.model.path);
      const failedManifest = {
        ...manifest,
        status: 'failed',
        failedAt,
        completedSuites: [...completedSuites],
        eventDiagnostics: driver?.eventDiagnostics ?? null,
        error: { message },
      };
      await input.sink.writeJson('manifest.json', failedManifest);
      await input.sink.writeJson('FAILED.json', {
        schemaVersion: 1,
        runId: input.sink.runId,
        suite: input.suite,
        collectorNonce,
        failedAt,
        completedSuites: [...completedSuites],
        error: { message },
      });
      this.progress('failed', completedSuites.length, completedSuites.length, message);
      throw new Error(message);
    } finally {
      driver?.close();
    }
  }

  private makeManifest(
    input: RunQualificationInput,
    collectorNonce: string | null,
    startedAt: string,
    completedSuites: readonly string[],
  ): Record<string, unknown> {
    const appCommit = parseQualificationRcCommit(input.app.appCommit);
    return {
      schemaVersion: 1,
      workloadVersion: M4_WORKLOAD_VERSION,
      runId: input.sink.runId,
      collectorNonce,
      status: 'running',
      selectedSuite: input.suite,
      selectedSuites:
        input.suite === 'all'
          ? ['reproducibility', 'utf8', 'cancellation', 'memory', 'benchmark']
          : ['memory'],
      startedAt,
      completedSuites: [...completedSuites],
      scope: {
        resultClass: 'iOS Simulator qualification',
        physicalDeviceClaim: false,
        externalInstrumentsRequiredForPostUnloadRss: true,
        nativeSentryTested: false,
      },
      app: { ...input.app, appCommit },
      sourceBinding: {
        appCommit,
        appCommitEmbedded: appCommit !== null,
        note:
          appCommit === null
            ? 'No valid 40-hex RC commit was embedded; the host collector must not treat this run as commit-bound.'
            : 'The 40-hex RC commit was embedded at JavaScript bundle build time.',
      },
      model: {
        id: input.model.model.id,
        displayName: input.model.model.displayName,
        family: input.model.model.family,
        sourceRepository: input.model.model.repository,
        sourceRevision: input.model.model.revision,
        sourceFilename: input.model.model.filename,
        installedFilename: input.model.model.installedFilename,
        byteSize: input.model.model.byteSize,
        sha256: input.model.model.sha256,
        quantization: input.model.model.quantization,
        installedAt: input.model.manifest.installedAt,
      },
      sessionConfig: M4_SESSION_CONFIG,
      fixedParameters: M4_PARAMS,
      workloadCounts: {
        reproducibilityRuns: 5,
        utf8SourceCases: 25,
        utf8InstructionVariants: 4,
        utf8Generations: UTF8_CORPUS.length,
        cancellationTrials: 20,
        memoryPrimingCyclesExcluded: 1,
        memoryMeasuredCycles: 10,
        benchmarkWarmupsExcluded: 1,
        benchmarkPrompts: BENCHMARK_PROMPTS.length,
        benchmarkPasses: BENCHMARK_ORDER.length,
        benchmarkMeasuredRuns:
          BENCHMARK_PROMPTS.length * BENCHMARK_ORDER.length,
      },
      limitations: [
        'Native peakRssBytes is a sampled process peak, not a post-unload RSS measurement.',
        'Post-unload RSS and leaks require the separately preserved Instruments trace.',
        'Simulator timings are not physical-device or thermal-performance evidence.',
      ],
    };
  }

  private async checkpointManifest(
    input: RunQualificationInput,
    manifest: Record<string, unknown>,
    completedSuites: readonly string[],
  ): Promise<void> {
    await input.sink.writeJson('manifest.json', {
      ...manifest,
      status: 'running',
      completedSuites: [...completedSuites],
      updatedAt: this.clock.wallClockIso(),
    });
  }

  private async loadSession(modelPath: string): Promise<SessionRecord> {
    const sessionId = await this.native.loadModel(modelPath, M4_SESSION_CONFIG);
    if (!isPositiveInt32(sessionId)) {
      throw new Error(`Native load returned invalid session ID ${String(sessionId)}.`);
    }
    const loaded = this.stamp();
    try {
      const diagnostics = cloneDiagnostics(
        await this.native.getDiagnostics(sessionId),
      );
      if (diagnostics.selectedAccelerator !== 'cpu') {
        throw new Error(
          `Qualification requires CPU Simulator scope, got ${diagnostics.selectedAccelerator}.`,
        );
      }
      return { sessionId, loaded, diagnostics };
    } catch (error: unknown) {
      await this.native.unloadModel(sessionId);
      throw error;
    }
  }

  private async unloadSession(sessionId: number): Promise<void> {
    await this.native.unloadModel(sessionId);
  }

  private async runReproducibility(
    input: RunQualificationInput,
    driver: NativeGenerationDriver,
  ): Promise<void> {
    const runs: {
      run: number;
      diagnostics: BackendDiagnostics;
      generation: GenerationCapture;
    }[] = [];
    for (let index = 0; index < 5; index += 1) {
      this.progress(
        'reproducibility',
        index,
        5,
        `Fresh seeded run ${String(index + 1)} of 5`,
      );
      const session = await this.loadSession(input.model.path);
      try {
        runs.push({
          run: index + 1,
          diagnostics: session.diagnostics,
          generation: await driver.generate(
            session.sessionId,
            singleUserMessage(REPRODUCIBILITY_PROMPT),
            M4_PARAMS.reproducibility,
          ),
        });
      } finally {
        await this.unloadSession(session.sessionId);
      }
      await input.sink.writeJson('reproducibility.json', {
        schemaVersion: 1,
        workloadVersion: M4_WORKLOAD_VERSION,
        status: 'running',
        prompt: REPRODUCIBILITY_PROMPT,
        requiredRunCount: 5,
        completedRunCount: runs.length,
        params: M4_PARAMS.reproducibility,
        freshSessionPerRun: true,
        runs,
      });
    }
    const first = runs[0]?.generation;
    const identical =
      first !== undefined &&
      first.output.length > 0 &&
      first.terminal.stats.generatedTokens > 0 &&
      runs.every(
        ({ generation }) =>
          generation.output === first.output &&
          generation.outputUtf8Hex === first.outputUtf8Hex &&
          generation.terminal.reason === first.terminal.reason &&
          generation.terminal.stats.generatedTokens ===
            first.terminal.stats.generatedTokens &&
          generation.postTerminalEventCount === 0,
      );
    const artifact = {
      schemaVersion: 1,
      workloadVersion: M4_WORKLOAD_VERSION,
      status: identical ? 'passed' : 'failed',
      prompt: REPRODUCIBILITY_PROMPT,
      requiredRunCount: 5,
      completedRunCount: runs.length,
      params: M4_PARAMS.reproducibility,
      freshSessionPerRun: true,
      exactOutputAndTerminalIdentity: identical,
      runs,
    };
    await input.sink.writeJson('reproducibility.json', artifact);
    if (!identical) {
      throw new Error('Five seeded fresh-session outputs were not identical.');
    }
  }

  private async runUtf8(
    input: RunQualificationInput,
    driver: NativeGenerationDriver,
  ): Promise<void> {
    const cases: {
      ordinal: number;
      id: string;
      category: string;
      prompt: string;
      generation: GenerationCapture;
    }[] = [];
    const session = await this.loadSession(input.model.path);
    try {
      for (let index = 0; index < UTF8_CORPUS.length; index += 1) {
        const corpusCase = UTF8_CORPUS[index];
        this.progress(
          'utf8',
          index,
          UTF8_CORPUS.length,
          `UTF-8 generation ${String(index + 1)} of ${String(UTF8_CORPUS.length)}`,
        );
        const generation = await driver.generate(
          session.sessionId,
          singleUserMessage(corpusCase.prompt),
          M4_PARAMS.utf8,
        );
        cases.push({
          ordinal: index + 1,
          id: corpusCase.id,
          category: corpusCase.category,
          prompt: corpusCase.prompt,
          generation,
        });
        if ((index + 1) % 10 === 0) {
          await input.sink.writeJson('utf8.json', {
            schemaVersion: 1,
            workloadVersion: M4_WORKLOAD_VERSION,
            status: 'running',
            corpusConstruction: '25 frozen emoji+CJK+RTL sources x 4 frozen instructions',
            requiredGenerationCount: 100,
            completedGenerationCount: cases.length,
            params: M4_PARAMS.utf8,
            cases,
          });
        }
      }
    } finally {
      await this.unloadSession(session.sessionId);
    }

    const passed =
      cases.length === 100 &&
      cases.every(
        ({ generation }) =>
          generation.unicodeScalarValid &&
          generation.tokenIndicesContiguous &&
          generation.terminalCount === 1 &&
          generation.postTerminalEventCount === 0 &&
          generation.output.length > 0 &&
          generation.terminal.stats.generatedTokens > 0 &&
          isUnicodeScalarString(generation.output),
      );
    await input.sink.writeJson('utf8.json', {
      schemaVersion: 1,
      workloadVersion: M4_WORKLOAD_VERSION,
      status: passed ? 'passed' : 'failed',
      corpusConstruction: '25 frozen emoji+CJK+RTL sources x 4 frozen instructions',
      requiredGenerationCount: 100,
      completedGenerationCount: cases.length,
      params: M4_PARAMS.utf8,
      allOutputsValidUnicodeScalars: passed,
      cases,
    });
    if (!passed) throw new Error('The 100-generation UTF-8 qualification failed.');
  }

  private async runCancellation(
    input: RunQualificationInput,
    driver: NativeGenerationDriver,
  ): Promise<void> {
    const trials: {
      trial: number;
      generation: GenerationCapture;
      underLimit: boolean;
    }[] = [];
    const session = await this.loadSession(input.model.path);
    let recoveryProbe: GenerationCapture;
    try {
      for (let index = 0; index < 20; index += 1) {
        this.progress(
          'cancellation',
          index,
          20,
          `Cancellation trial ${String(index + 1)} of 20`,
        );
        const generation = await driver.generate(
          session.sessionId,
          singleUserMessage(CANCELLATION_PROMPT),
          M4_PARAMS.cancellation,
          { cancelOnFirstToken: true },
        );
        const latency = generation.cancellation?.latencyMs;
        trials.push({
          trial: index + 1,
          generation,
          underLimit:
            latency !== undefined && latency >= 0 && latency < CANCELLATION_LIMIT_MS,
        });
        if ((index + 1) % 5 === 0) {
          await input.sink.writeJson('cancellation.json', {
            schemaVersion: 1,
            workloadVersion: M4_WORKLOAD_VERSION,
            status: 'running',
            timingBoundary:
              'immediately before cancel invocation through matching DONE(cancelled) listener delivery',
            cancellationInitiation: 'after first matching token event was observed',
            strictLimitMs: CANCELLATION_LIMIT_MS,
            requiredTrialCount: 20,
            completedTrialCount: trials.length,
            params: M4_PARAMS.cancellation,
            trials,
          });
        }
      }
      this.progress(
        'cancellation',
        20,
        20,
        'Final same-session post-cancel recovery probe',
      );
      recoveryProbe = await driver.generate(
        session.sessionId,
        singleUserMessage('Reply with the single uppercase word OK.'),
        M4_PARAMS.memory,
      );
    } finally {
      await this.unloadSession(session.sessionId);
    }
    const passed =
      trials.length === 20 &&
      trials.every(
        ({ generation, underLimit }) =>
          underLimit &&
          generation.cancellation !== null &&
          generation.firstTokenDelivered !== null &&
          generation.terminal.reason === 'cancelled',
      ) &&
      recoveryProbe.output.length > 0 &&
      recoveryProbe.terminal.stats.generatedTokens > 0 &&
      recoveryProbe.terminal.reason !== 'cancelled' &&
      recoveryProbe.postTerminalEventCount === 0;
    await input.sink.writeJson('cancellation.json', {
      schemaVersion: 1,
      workloadVersion: M4_WORKLOAD_VERSION,
      status: passed ? 'passed' : 'failed',
      timingBoundary:
        'immediately before cancel invocation through matching DONE(cancelled) listener delivery',
      cancellationInitiation: 'after first matching token event was observed',
      strictLimitMs: CANCELLATION_LIMIT_MS,
      requiredTrialCount: 20,
      completedTrialCount: trials.length,
      allTrialsStrictlyUnderLimit: passed,
      sameSessionAcrossAllTrials: trials.every(
        ({ generation }) => generation.sessionId === session.sessionId,
      ),
      finalPostCancelRecoveryProbeExcludedFromLatencyTrials: recoveryProbe,
      params: M4_PARAMS.cancellation,
      trials,
    });
    if (!passed) {
      throw new Error('At least one cancellation trial was not strictly under 200 ms.');
    }
  }

  private async runMemory(
    input: RunQualificationInput,
    driver: NativeGenerationDriver,
  ): Promise<void> {
    const cycles: Record<string, unknown>[] = [];
    for (let cycleIndex = 0; cycleIndex < 11; cycleIndex += 1) {
      const included = cycleIndex > 0;
      const displayIndex = included ? cycleIndex : 0;
      this.progress(
        'memory',
        cycleIndex,
        11,
        included
          ? `Measured memory cycle ${String(displayIndex)} of 10: pre-load`
          : 'Excluded memory priming cycle: pre-load',
      );
      const markers: (Timestamp & { phase: string })[] = [];
      const mark = (phase: string): Timestamp & { phase: string } => {
        const marker = { phase, ...this.stamp() };
        markers.push(marker);
        return marker;
      };
      const preLoad = mark('pre-load');
      const session = await this.loadSession(input.model.path);
      const postLoad = { phase: 'post-load', ...session.loaded };
      markers.push(postLoad);
      mark('post-load-diagnostics');
      let generation: GenerationCapture;
      let postGenerationDiagnostics: BackendDiagnostics;
      let preUnload: Timestamp & { phase: string };
      let postUnload: Timestamp & { phase: string };
      try {
        this.progress(
          'memory',
          cycleIndex,
          11,
          included
            ? `Measured memory cycle ${String(displayIndex)} of 10: generating`
            : 'Excluded memory priming cycle: generating',
        );
        generation = await driver.generate(
          session.sessionId,
          singleUserMessage(MEMORY_PROMPT),
          M4_PARAMS.memory,
        );
        mark('post-terminal');
        postGenerationDiagnostics = cloneDiagnostics(
          await this.native.getDiagnostics(session.sessionId),
        );
        mark('post-terminal-diagnostics');
        preUnload = mark('pre-unload');
      } finally {
        await this.unloadSession(session.sessionId);
        postUnload = mark('post-unload');
      }
      this.progress(
        'memory',
        cycleIndex,
        11,
        included
          ? `Measured memory cycle ${String(displayIndex)} of 10: post-unload ${String(this.lifecycleSettleMs)} ms settle`
          : `Excluded memory priming cycle: post-unload ${String(this.lifecycleSettleMs)} ms settle`,
      );
      await this.delay(this.lifecycleSettleMs);
      mark('post-unload-settle');
      this.progress(
        'memory',
        cycleIndex + 1,
        11,
        included
          ? `Measured memory cycle ${String(displayIndex)} of 10 complete`
          : 'Excluded memory priming cycle complete',
      );

      const record = {
        ordinal: cycleIndex + 1,
        kind: included ? 'measured' : 'priming-excluded',
        measuredCycle: included ? cycleIndex : null,
        includedInMemorySeries: included,
        sessionId: session.sessionId,
        markers,
        lifecycleDurationsMs: {
          load: postLoad.monotonicMs - preLoad.monotonicMs,
          unload: postUnload.monotonicMs - preUnload.monotonicMs,
        },
        afterLoadDiagnostics: session.diagnostics,
        postTerminalDiagnostics: postGenerationDiagnostics,
        generation,
        rssMetricSemantics: {
          afterLoadDiagnosticsPeakRssBytes:
            'native sampled process peak while session is loaded',
          generationPeakRssBytes:
            'native sampled process peak reported at request terminal',
          postTerminalDiagnosticsPeakRssBytes:
            'native sampled process peak before unload',
          postUnloadRssBytes: null,
          postUnloadRssSource: 'external Instruments trace only',
        },
      };
      cycles.push(record);
      await input.sink.writeJson('memory.json', {
        schemaVersion: 1,
        workloadVersion: M4_WORKLOAD_VERSION,
        status: 'running',
        method:
          'one excluded priming cycle followed by ten load/generate/unload cycles in one process',
        requiredMeasuredCycles: 10,
        completedMeasuredCycles: Math.max(0, cycles.length - 1),
        primingCycleCount: Math.min(1, cycles.length),
        lifecycleSettleMs: this.lifecycleSettleMs,
        params: M4_PARAMS.memory,
        cycles,
      });
    }
    const measured = cycles.filter(
      (cycle) => cycle['includedInMemorySeries'] === true,
    );
    const everyCycleGenerated = cycles.every((cycle) => {
      const generation = cycle['generation'] as GenerationCapture | undefined;
      return (
        generation !== undefined &&
        generation.output.length > 0 &&
        generation.terminal.stats.generatedTokens > 0 &&
        generation.terminalCount === 1 &&
        generation.postTerminalEventCount === 0
      );
    });
    const passed =
      cycles.length === 11 && measured.length === 10 && everyCycleGenerated;
    await input.sink.writeJson('memory.json', {
      schemaVersion: 1,
      workloadVersion: M4_WORKLOAD_VERSION,
      status: passed ? 'completed' : 'failed',
      method:
        'one excluded priming cycle followed by ten load/generate/unload cycles in one process',
      requiredMeasuredCycles: 10,
      completedMeasuredCycles: measured.length,
      primingCycleCount: cycles.length - measured.length,
      lifecycleSettleMs: this.lifecycleSettleMs,
      params: M4_PARAMS.memory,
      memoryCeilingAssertedByApp: false,
      note:
        'This artifact preserves lifecycle markers and available native peaks; the Instruments trace owns post-unload RSS/leak interpretation.',
      cycles,
    });
    if (!passed) throw new Error('Memory lifecycle did not complete ten measured cycles.');
  }

  private async runBenchmark(
    input: RunQualificationInput,
    driver: NativeGenerationDriver,
  ): Promise<void> {
    const session = await this.loadSession(input.model.path);
    let warmup: GenerationCapture;
    const runs: Record<string, unknown>[] = [];
    try {
      this.progress('benchmark', 0, 16, 'Excluded benchmark warmup');
      warmup = await driver.generate(
        session.sessionId,
        singleUserMessage(BENCHMARK_PROMPTS[0].prompt),
        M4_PARAMS.benchmark,
      );
      let measuredOrdinal = 0;
      for (let passIndex = 0; passIndex < BENCHMARK_ORDER.length; passIndex += 1) {
        const order = BENCHMARK_ORDER[passIndex];
        for (let position = 0; position < order.length; position += 1) {
          measuredOrdinal += 1;
          const promptIndex = order[position];
          const prompt = BENCHMARK_PROMPTS[promptIndex];
          this.progress(
            'benchmark',
            measuredOrdinal + 1,
            16,
            `Benchmark pass ${String(passIndex + 1)} of 3, position ${String(position + 1)} of 5`,
          );
          const generation = await driver.generate(
            session.sessionId,
            singleUserMessage(prompt.prompt),
            M4_PARAMS.benchmark,
          );
          const stats = generation.terminal.stats;
          runs.push({
            measuredOrdinal,
            pass: passIndex + 1,
            position: position + 1,
            promptIndex,
            promptId: prompt.id,
            qualityDimension: prompt.qualityDimension,
            prompt: prompt.prompt,
            generation,
            derived: {
              decodeTokensPerSecond:
                stats.decodeMs > 0
                  ? (stats.generatedTokens * 1000) / stats.decodeMs
                  : null,
              nativeInferenceTokensPerSecond:
                stats.prefillMs + stats.decodeMs > 0
                  ? (stats.generatedTokens * 1000) /
                    (stats.prefillMs + stats.decodeMs)
                  : null,
              endToEndTokensPerSecond:
                generation.terminalDelivered.monotonicMs -
                  generation.requestAccepted.monotonicMs >
                0
                  ? (stats.generatedTokens * 1000) /
                    (generation.terminalDelivered.monotonicMs -
                      generation.requestAccepted.monotonicMs)
                  : null,
              timeToFirstDeliveredFragmentMs:
                generation.firstTokenDelivered === null
                  ? null
                  : generation.firstTokenDelivered.monotonicMs -
                    generation.requestAccepted.monotonicMs,
            },
          });
        }
      }
    } finally {
      await this.unloadSession(session.sessionId);
    }
    const passed =
      runs.length === 15 &&
      warmup.output.length > 0 &&
      warmup.terminal.stats.generatedTokens > 0 &&
      warmup.postTerminalEventCount === 0 &&
      runs.every((run) => {
        const generation = run['generation'] as GenerationCapture | undefined;
        return (
          generation !== undefined &&
          generation.output.length > 0 &&
          generation.terminal.stats.generatedTokens > 0 &&
          generation.terminalCount === 1 &&
          generation.postTerminalEventCount === 0
        );
      });
    await input.sink.writeJson('benchmark.json', {
      schemaVersion: 1,
      workloadVersion: M4_WORKLOAD_VERSION,
      status: passed ? 'completed' : 'failed',
      executionOrder: 'pass-major preregistered rotations',
      promptTable: BENCHMARK_PROMPTS,
      zeroBasedPromptOrderByPass: BENCHMARK_ORDER,
      warmupExcludedFromMeasuredRuns: true,
      excludedWarmup: warmup,
      requiredMeasuredRunCount: 15,
      completedMeasuredRunCount: runs.length,
      params: M4_PARAMS.benchmark,
      rawRuns: runs,
      derivation:
        'decode rate uses native decodeMs; native inference rate uses prefillMs + decodeMs; delivered end-to-end rate uses request acceptance through terminal listener delivery; raw timestamps and terminal stats remain authoritative',
    });
    if (!passed) throw new Error('Benchmark did not complete five prompts by three runs.');
  }

  private progress(
    phase: QualificationPhase,
    completed: number,
    total: number,
    detail: string,
  ): void {
    this.onProgress({ phase, completed, total, detail });
  }

  private stamp(): Timestamp {
    return {
      wallClock: this.clock.wallClockIso(),
      monotonicMs: this.clock.monotonicMs(),
    };
  }
}
