import {
  InferenceCoordinator,
  buildNativeMessages,
  parseInferenceEvent,
  type InferenceSubscription,
  type NativeInferenceModule,
} from '../src/features/inference/coordinator';
import { SharedInferenceRuntime } from '../src/features/inference/runtime';
import type { BackendDiagnostics } from '../src/lib/NativePocketLM';
import type { ChatAction, ChatState, InferenceEvent } from '../src/features/inference/types';
import { chatReducer, INITIAL_STATE } from '../src/state/AppContext';

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (reason: unknown) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

class FakeEventSource {
  listener: ((event: unknown) => void) | null = null;
  subscribeCount = 0;
  removeCount = 0;

  subscribe = (listener: (event: unknown) => void): InferenceSubscription => {
    this.listener = listener;
    this.subscribeCount += 1;
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

class FakeNative implements NativeInferenceModule {
  callOrder: string[] = [];
  loadCalls: Parameters<NativeInferenceModule['loadModel']>[] = [];
  unloadCalls: Parameters<NativeInferenceModule['unloadModel']>[] = [];
  diagnosticsCalls: Parameters<NativeInferenceModule['getDiagnostics']>[] = [];
  generateCalls: Parameters<NativeInferenceModule['generate']>[] = [];
  cancelCalls: Parameters<NativeInferenceModule['cancel']>[] = [];

  loadImplementation: () => Promise<number> = async () => 3;
  unloadImplementation: () => Promise<void> = async () => undefined;
  diagnosticsImplementation: () => Promise<BackendDiagnostics> = async () =>
    DEFAULT_DIAGNOSTICS;
  generateImplementation: () => number = () => 41;

  loadModel(
    ...args: Parameters<NativeInferenceModule['loadModel']>
  ): Promise<number> {
    this.callOrder.push('load');
    this.loadCalls.push(args);
    return this.loadImplementation();
  }

  unloadModel(
    ...args: Parameters<NativeInferenceModule['unloadModel']>
  ): Promise<void> {
    this.callOrder.push('unload');
    this.unloadCalls.push(args);
    return this.unloadImplementation();
  }

  getDiagnostics(
    ...args: Parameters<NativeInferenceModule['getDiagnostics']>
  ): Promise<BackendDiagnostics> {
    this.callOrder.push('diagnostics');
    this.diagnosticsCalls.push(args);
    return this.diagnosticsImplementation();
  }

  generate(...args: Parameters<NativeInferenceModule['generate']>): number {
    this.callOrder.push('generate');
    this.generateCalls.push(args);
    return this.generateImplementation();
  }

  cancel(...args: Parameters<NativeInferenceModule['cancel']>): void {
    this.callOrder.push('cancel');
    this.cancelCalls.push(args);
  }
}

const DEFAULT_DIAGNOSTICS: BackendDiagnostics = {
  requestedAccelerator: 'auto',
  selectedAccelerator: 'cpu',
  contextSize: 2048,
  batchSize: 512,
  modelLayers: 24,
  offloadedLayers: 0,
  kqvOffloaded: false,
  peakRssBytes: 1024,
};

const DONE_STATS = {
  prefillMs: 1,
  decodeMs: 2,
  promptTokens: 3,
  generatedTokens: 4,
  peakRssBytes: 5,
};

function token(
  sessionId: number,
  requestId: number,
  index: number,
  text: string,
  tokenCount = 1,
): InferenceEvent {
  return { type: 'token', sessionId, requestId, index, tokenCount, text };
}

function done(
  sessionId: number,
  requestId: number,
  reason: Extract<InferenceEvent, { type: 'done' }>['reason'] = 'eos',
): InferenceEvent {
  return { type: 'done', sessionId, requestId, reason, stats: DONE_STATS };
}

function nativeError(
  sessionId: number,
  requestId: number,
  message: string,
): InferenceEvent {
  return {
    type: 'error',
    sessionId,
    requestId,
    code: 'DECODE_FAILED',
    message,
  };
}

type Harness = {
  coordinator: InferenceCoordinator;
  native: FakeNative;
  events: FakeEventSource;
  getState: () => ChatState;
  actions: ChatAction[];
  reports: unknown[];
  diagnostics: Array<{ message: string; details: unknown }>;
};

function createHarness(options: { loaded?: boolean; start?: boolean } = {}): Harness {
  let state: ChatState = options.loaded
    ? {
        ...INITIAL_STATE,
        sessionId: 3,
        modelPath: '/verified/model.gguf',
        diagnostics: DEFAULT_DIAGNOSTICS,
      }
    : { ...INITIAL_STATE, messages: [] };
  const native = new FakeNative();
  const events = new FakeEventSource();
  const actions: ChatAction[] = [];
  const reports: unknown[] = [];
  const diagnostics: Array<{ message: string; details: unknown }> = [];
  let nextId = 1;
  const coordinator = new InferenceCoordinator({
    native,
    subscribe: events.subscribe,
    getState: () => state,
    dispatch: (action) => {
      actions.push(action);
      state = chatReducer(state, action);
    },
    resolveModelPath: () => '/verified/model.gguf',
    makeId: () => `id-${String(nextId++)}`,
    reportError: (error) => reports.push(error),
    reportDiagnostic: (message, details) => diagnostics.push({ message, details }),
    watchdogMs: 100,
  });
  if (options.start !== false) coordinator.start();
  return {
    coordinator,
    native,
    events,
    getState: () => state,
    actions,
    reports,
    diagnostics,
  };
}

describe('InferenceCoordinator', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('sets up one listener and removes it idempotently', () => {
    const harness = createHarness({ start: false });
    harness.coordinator.start();
    harness.coordinator.start();
    expect(harness.events.subscribeCount).toBe(1);

    harness.coordinator.stop();
    harness.coordinator.stop();
    expect(harness.events.removeCount).toBe(1);
    expect(harness.events.listener).toBeNull();
  });

  it('admits only one of two same-tick submissions', async () => {
    const harness = createHarness();
    const load = deferred<number>();
    harness.native.loadImplementation = () => load.promise;

    const first = harness.coordinator.submit('first');
    const second = harness.coordinator.submit('second');
    expect(first.admitted).toBe(true);
    expect(second.admitted).toBe(false);
    expect(harness.native.loadCalls).toHaveLength(1);
    expect(harness.getState().messages).toHaveLength(2);

    let rejectedDraft = 'second';
    if (second.admitted) rejectedDraft = '';
    expect(rejectedDraft).toBe('second');

    load.resolve(3);
    await Promise.all([first.completion, second.completion]);
    expect(harness.native.generateCalls).toHaveLength(1);
    expect(harness.coordinator.active).toEqual({
      sessionId: 3,
      requestId: 41,
      assistantId: 'id-2',
      expectedTokenIndex: 0,
      phase: 'generating',
    });
  });

  it('loads, captures diagnostics, then generates in that exact order', async () => {
    const harness = createHarness();

    await harness.coordinator.submit('hello').completion;

    expect(harness.native.callOrder).toEqual([
      'load',
      'diagnostics',
      'generate',
    ]);
    expect(harness.native.diagnosticsCalls).toEqual([[3]]);
    expect(harness.getState().diagnostics).toEqual(DEFAULT_DIAGNOSTICS);
    expect(harness.getState().sessionId).toBe(3);
    expect(harness.native.generateCalls[0]?.[1]).toEqual([
      { role: 'user', content: 'hello' },
    ]);
  });

  it('unloads and fails without generating when diagnostics retrieval fails', async () => {
    const harness = createHarness();
    harness.native.diagnosticsImplementation = async () => {
      throw Object.assign(new Error('diagnostics unavailable'), {
        code: 'INTERNAL',
      });
    };

    await harness.coordinator.submit('hello').completion;

    expect(harness.native.callOrder).toEqual([
      'load',
      'diagnostics',
      'unload',
    ]);
    expect(harness.native.unloadCalls).toEqual([[3]]);
    expect(harness.native.generateCalls).toHaveLength(0);
    expect(harness.getState().sessionId).toBeNull();
    expect(harness.getState().diagnostics).toBeNull();
    expect(harness.getState().status).toEqual({
      kind: 'error',
      code: 'INTERNAL',
      message:
        'Unable to read native backend diagnostics: diagnostics unavailable',
    });
    const assistant = harness.getState().messages[1];
    expect(assistant?.role).toBe('assistant');
    if (assistant?.role === 'assistant') {
      expect(assistant.outcome).toBe('failed');
      expect(assistant.errorCode).toBe('INTERNAL');
    }
  });

  it('shares diagnostics cleanup with reset instead of unloading twice', async () => {
    const harness = createHarness();
    const diagnostics = deferred<BackendDiagnostics>();
    const cleanup = deferred<void>();
    harness.native.diagnosticsImplementation = () => diagnostics.promise;
    harness.native.unloadImplementation = () => cleanup.promise;

    const submission = harness.coordinator.submit('hello');
    diagnostics.reject(new Error('diagnostics unavailable'));
    await Promise.resolve();
    await Promise.resolve();
    expect(harness.native.unloadCalls).toEqual([[3]]);

    const reset = harness.coordinator.reset();
    expect(harness.native.unloadCalls).toEqual([[3]]);
    cleanup.resolve(undefined);
    await Promise.all([submission.completion, reset]);

    expect(harness.native.unloadCalls).toEqual([[3]]);
    expect(harness.native.generateCalls).toHaveLength(0);
    expect(harness.getState()).toEqual(INITIAL_STATE);
  });

  it('never enters generating state for a negative native result', async () => {
    const harness = createHarness({ loaded: true });
    harness.native.generateImplementation = () => -2;

    const first = harness.coordinator.submit('hello');
    const sameTurn = harness.coordinator.submit('must-not-start');
    expect(first.admitted).toBe(true);
    expect(sameTurn.admitted).toBe(false);
    expect(harness.native.generateCalls).toHaveLength(1);
    await first.completion;
    expect(harness.coordinator.active).toBeNull();
    expect(harness.getState().status.kind).toBe('error');
    expect(
      harness.actions.some((action) => action.type === 'GENERATION_STARTED'),
    ).toBe(false);
    expect(harness.coordinator.controlState.busy).toBe(false);
  });

  it('reports a thrown generate failure and releases the pre-acceptance lock', async () => {
    const harness = createHarness({ loaded: true });
    harness.native.generateImplementation = () => {
      throw new Error('bridge rejected call');
    };

    const first = harness.coordinator.submit('hello');
    const sameTurn = harness.coordinator.submit('must-not-start');
    expect(first.admitted).toBe(true);
    expect(sameTurn.admitted).toBe(false);
    expect(harness.native.generateCalls).toHaveLength(1);
    await first.completion;
    expect(harness.coordinator.active).toBeNull();
    expect(harness.coordinator.controlState.busy).toBe(false);
    expect(harness.getState().status.kind).toBe('error');
    expect(harness.reports).toHaveLength(1);
  });

  it('buffers events emitted from the generate call stack until the tuple exists', async () => {
    const harness = createHarness({ loaded: true });
    harness.native.generateImplementation = () => {
      harness.events.emit(token(3, 41, 0, 'hello'));
      harness.events.emit(done(3, 41));
      return 41;
    };

    const first = harness.coordinator.submit('prompt');
    const sameTurn = harness.coordinator.submit('must-not-start');
    expect(first.admitted).toBe(true);
    expect(sameTurn.admitted).toBe(false);
    await first.completion;
    expect(harness.getState().messages[1]?.content).toBe('hello');
    expect(harness.getState().messages[1]?.streaming).toBe(false);
    expect(harness.getState().status.kind).toBe('idle');
    expect(harness.coordinator.active).toBeNull();
  });

  it('correlates IDs and ignores every token event below the expected index', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('prompt').completion;

    harness.events.emit(token(4, 41, 0, 'wrong-session'));
    harness.events.emit(token(3, 42, 0, 'wrong-request'));
    expect(harness.diagnostics).toEqual([
      {
        message: 'Discarded stale native inference event.',
        details: {
          reason: 'mismatched-active-request',
          active: { sessionId: 3, requestId: 41 },
          received: { sessionId: 4, requestId: 41 },
        },
      },
      {
        message: 'Discarded stale native inference event.',
        details: {
          reason: 'mismatched-active-request',
          active: { sessionId: 3, requestId: 41 },
          received: { sessionId: 3, requestId: 42 },
        },
      },
    ]);
    harness.events.emit(token(3, 41, 0, 'ab', 2));
    harness.events.emit(token(3, 41, 0, 'duplicate', 2));
    expect(harness.getState().messages[1]?.content).toBe('ab');
    expect(harness.coordinator.active?.expectedTokenIndex).toBe(2);

    // Even though this coalesced range crosses the expected index, the frozen
    // protocol classifies any event whose first index is lower as duplicate.
    harness.events.emit(token(3, 41, 1, 'overlap', 2));
    expect(harness.getState().status.kind).toBe('generating');
    expect(harness.coordinator.active?.phase).toBe('generating');
    expect(harness.coordinator.active?.expectedTokenIndex).toBe(2);
    expect(harness.native.cancelCalls).toHaveLength(0);

    harness.events.emit(token(3, 41, 2, 'c'));
    expect(harness.getState().messages[1]?.content).toBe('abc');
    harness.events.emit(done(3, 41));
    expect(harness.coordinator.active).toBeNull();
    expect(harness.getState().status.kind).toBe('idle');
    expect(harness.coordinator.canRetry).toBe(false);
  });

  it('treats a gap or malformed matching payload as a cancelling transport fault', async () => {
    const gap = createHarness({ loaded: true });
    await gap.coordinator.submit('prompt').completion;
    gap.events.emit(token(3, 41, 1, 'gap'));
    gap.coordinator.cancel();
    expect(gap.native.cancelCalls).toEqual([[3, 41]]);
    expect(gap.coordinator.controlState.busy).toBe(true);

    const malformed = createHarness({ loaded: true });
    await malformed.coordinator.submit('prompt').completion;
    malformed.events.emit({
      type: 'token',
      sessionId: 99,
      requestId: 41,
      index: 0,
      tokenCount: 0,
      text: '',
    });
    expect(malformed.native.cancelCalls).toHaveLength(0);
    malformed.events.emit({
      type: 'token',
      sessionId: 3,
      requestId: 41,
      index: 0,
      tokenCount: 0,
      text: '',
    });
    expect(malformed.native.cancelCalls).toEqual([[3, 41]]);
    expect(malformed.reports).toHaveLength(1);
  });

  it('accepts a valid zero-token terminal and ignores duplicate/post-terminal events', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('prompt').completion;
    harness.events.emit(done(3, 41, 'context_exhausted'));
    harness.events.emit(done(3, 41));
    harness.events.emit(token(3, 41, 0, 'late'));

    expect(harness.coordinator.active).toBeNull();
    expect(harness.getState().messages[1]?.content).toBe('');
    expect(harness.getState().messages[1]?.streaming).toBe(false);
    const assistant = harness.getState().messages[1];
    expect(assistant?.role).toBe('assistant');
    if (assistant?.role === 'assistant') {
      expect(assistant.outcome).toBe('complete');
      expect(assistant.finishReason).toBe('context_exhausted');
      expect(assistant.stats).toEqual(DONE_STATS);
    }
    expect(
      harness.actions.filter((action) => action.type === 'DONE'),
    ).toHaveLength(1);
  });

  it('makes cancel idempotent and waits for the matching terminal', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('prompt').completion;

    harness.coordinator.cancel();
    harness.coordinator.cancel();
    expect(harness.native.cancelCalls).toEqual([[3, 41]]);
    expect(harness.coordinator.active?.phase).toBe('cancelling');
    expect(harness.getState().status.kind).toBe('generating');
    expect(harness.getState().messages[1]?.streaming).toBe(true);

    harness.events.emit(token(3, 41, 0, 'ignored'));
    harness.events.emit(done(3, 41, 'cancelled'));
    expect(harness.coordinator.active).toBeNull();
    expect(harness.getState().status.kind).toBe('idle');
    expect(harness.getState().messages[1]?.streaming).toBe(false);
  });

  it('semantically omits cancelled partial turns from later history', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('cancel me').completion;
    harness.events.emit(token(3, 41, 0, 'partial'));
    harness.coordinator.cancel();
    harness.events.emit(done(3, 41, 'cancelled'));

    harness.native.generateImplementation = () => 42;
    await harness.coordinator.submit('next').completion;
    expect(harness.native.generateCalls[1]?.[1]).toEqual([
      { role: 'user', content: 'next' },
    ]);
  });

  it('forwards complete multi-turn history as raw role/content messages', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('first user').completion;
    harness.events.emit(token(3, 41, 0, 'first assistant'));
    harness.events.emit(done(3, 41));

    harness.native.generateImplementation = () => 42;
    await harness.coordinator.submit('second user').completion;

    expect(harness.native.generateCalls[1]?.[1]).toEqual([
      { role: 'user', content: 'first user' },
      { role: 'assistant', content: 'first assistant' },
      { role: 'user', content: 'second user' },
    ]);
    expect(
      JSON.stringify(harness.native.generateCalls[1]?.[1]),
    ).not.toContain('<|im_');
  });

  it('persists cancellation and supersedes it before regeneration', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('try again').completion;
    harness.events.emit(token(3, 41, 0, 'partial'));
    harness.coordinator.cancel();
    harness.events.emit(done(3, 41, 'cancelled'));

    const cancelled = harness.getState().messages[1];
    expect(cancelled?.role).toBe('assistant');
    if (cancelled?.role === 'assistant') {
      expect(cancelled.outcome).toBe('cancelled');
      expect(cancelled.finishReason).toBe('cancelled');
      expect(cancelled.stats).toEqual(DONE_STATS);
    }
    expect(harness.coordinator.canRegenerate).toBe(true);

    harness.native.generateImplementation = () => 42;
    const regeneration = harness.coordinator.regenerate();
    expect(regeneration.admitted).toBe(true);
    await regeneration.completion;

    const superseded = harness.getState().messages[1];
    expect(superseded?.role).toBe('assistant');
    if (superseded?.role === 'assistant') {
      expect(superseded.outcome).toBe('superseded');
    }
    expect(harness.native.generateCalls[1]?.[1]).toEqual([
      { role: 'user', content: 'try again' },
    ]);
    expect(harness.coordinator.active?.requestId).toBe(42);
  });

  it('omits every prior failed attempt after repeated retry and later submit', async () => {
    const harness = createHarness({ loaded: true });
    harness.native.generateImplementation = () => -2;
    await harness.coordinator.submit('retry me').completion;
    await harness.coordinator.retry().completion;

    harness.native.generateImplementation = () => 43;
    await harness.coordinator.retry().completion;
    harness.events.emit(token(3, 43, 0, 'answer'));
    harness.events.emit(done(3, 43));

    harness.native.generateImplementation = () => 44;
    await harness.coordinator.submit('later').completion;
    expect(harness.native.generateCalls[3]?.[1]).toEqual([
      { role: 'user', content: 'retry me' },
      { role: 'assistant', content: 'answer' },
      { role: 'user', content: 'later' },
    ]);
  });

  it('clears ownership on a matching native error and succeeds on Retry', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('retry native error').completion;
    harness.events.emit(nativeError(3, 41, 'decode failed'));

    expect(harness.coordinator.active).toBeNull();
    expect(harness.coordinator.controlState.busy).toBe(false);
    expect(harness.coordinator.canRetry).toBe(true);
    expect(harness.getState().status.kind).toBe('error');
    expect(harness.getState().status).toEqual({
      kind: 'error',
      code: 'DECODE_FAILED',
      message: 'decode failed',
    });
    const failedAssistant = harness.getState().messages[1];
    expect(failedAssistant?.role).toBe('assistant');
    if (failedAssistant?.role === 'assistant') {
      expect(failedAssistant.outcome).toBe('failed');
      expect(failedAssistant.errorCode).toBe('DECODE_FAILED');
      expect(failedAssistant.errorMessage).toBe('decode failed');
    }

    harness.native.generateImplementation = () => 42;
    const retry = harness.coordinator.retry();
    expect(retry.admitted).toBe(true);
    await retry.completion;
    harness.events.emit(token(3, 42, 0, 'recovered'));
    harness.events.emit(done(3, 42));

    expect(harness.native.generateCalls).toHaveLength(2);
    expect(harness.coordinator.active).toBeNull();
    expect(harness.getState().status.kind).toBe('idle');
    const messages = harness.getState().messages;
    expect(messages[messages.length - 1]?.content).toBe('recovered');
  });

  it('uses an inactivity watchdog, cancels once, and blocks retry until terminal', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('prompt').completion;
    jest.advanceTimersByTime(90);
    harness.events.emit(token(3, 41, 0, 'a'));
    jest.advanceTimersByTime(99);
    expect(harness.native.cancelCalls).toHaveLength(0);

    jest.advanceTimersByTime(1);
    expect(harness.native.cancelCalls).toEqual([[3, 41]]);
    expect(harness.coordinator.active?.phase).toBe('cancelling');
    await harness.coordinator.retry().completion;
    expect(harness.native.generateCalls).toHaveLength(1);

    harness.events.emit(done(3, 41, 'cancelled'));
    harness.native.generateImplementation = () => 42;
    await harness.coordinator.retry().completion;
    expect(harness.native.generateCalls).toHaveLength(2);
    expect(harness.coordinator.active?.requestId).toBe(42);
  });

  it('awaits unload before reset clears ownership and excludes new submissions', async () => {
    const harness = createHarness({ loaded: true });
    const unload = deferred<void>();
    harness.native.unloadImplementation = () => unload.promise;
    await harness.coordinator.submit('prompt').completion;

    const reset = harness.coordinator.reset();
    const duplicateReset = harness.coordinator.reset();
    await harness.coordinator.submit('must-not-start').completion;
    expect(harness.native.cancelCalls).toEqual([[3, 41]]);
    expect(harness.native.unloadCalls).toEqual([[3]]);
    expect(harness.native.generateCalls).toHaveLength(1);
    expect(harness.coordinator.controlState.resetting).toBe(true);

    harness.events.emit(done(3, 41, 'cancelled'));
    expect(harness.coordinator.controlState.busy).toBe(true);
    unload.resolve(undefined);
    await Promise.all([reset, duplicateReset]);
    expect(harness.getState()).toEqual(INITIAL_STATE);
    expect(harness.coordinator.controlState.busy).toBe(false);
  });

  it('waits for an in-flight load, skips generate, then unloads before reset', async () => {
    const harness = createHarness();
    const load = deferred<number>();
    const unload = deferred<void>();
    harness.native.loadImplementation = () => load.promise;
    harness.native.unloadImplementation = () => unload.promise;

    const submission = harness.coordinator.submit('loading');
    const reset = harness.coordinator.reset();
    expect(submission.admitted).toBe(true);
    expect(harness.coordinator.controlState.resetting).toBe(true);

    load.resolve(7);
    await submission.completion;
    await Promise.resolve();
    expect(harness.native.generateCalls).toHaveLength(0);
    expect(harness.native.unloadCalls).toEqual([[7]]);
    expect(harness.coordinator.controlState.busy).toBe(true);

    unload.resolve(undefined);
    await reset;
    expect(harness.getState()).toEqual(INITIAL_STATE);
    expect(harness.coordinator.active).toBeNull();
    expect(harness.coordinator.controlState.busy).toBe(false);
  });

  it('reports load/unload rejection without prematurely clearing uncertain ownership', async () => {
    const loadFailure = createHarness();
    loadFailure.native.loadImplementation = async () => {
      throw new Error('load failed');
    };
    await loadFailure.coordinator.submit('prompt').completion;
    expect(loadFailure.getState().status.kind).toBe('error');
    expect(loadFailure.coordinator.controlState.busy).toBe(false);

    const unloadFailure = createHarness({ loaded: true });
    await unloadFailure.coordinator.submit('prompt').completion;
    unloadFailure.native.unloadImplementation = async () => {
      throw new Error('unload failed');
    };
    await unloadFailure.coordinator.reset();
    expect(unloadFailure.getState().status.kind).toBe('error');
    expect(unloadFailure.coordinator.active).not.toBeNull();
    expect(unloadFailure.coordinator.controlState.busy).toBe(true);
    await unloadFailure.coordinator.submit('must-not-start').completion;
    expect(unloadFailure.native.generateCalls).toHaveLength(1);
    unloadFailure.events.emit(done(3, 41, 'cancelled'));
    expect(unloadFailure.coordinator.active).toBeNull();
    expect(unloadFailure.getState().status.kind).toBe('error');
  });

  it('rejects old-session events after reset and reload', async () => {
    const harness = createHarness({ loaded: true });
    await harness.coordinator.submit('first').completion;
    harness.events.emit(done(3, 41));
    await harness.coordinator.reset();

    harness.native.loadImplementation = async () => 4;
    // IDs are session-scoped, so deliberately collide with the old session.
    harness.native.generateImplementation = () => 41;
    await harness.coordinator.submit('second').completion;
    harness.events.emit(token(3, 41, 0, 'old'));
    expect(harness.getState().messages[1]?.content).toBe('');
    expect(harness.diagnostics[harness.diagnostics.length - 1]).toEqual({
      message: 'Discarded stale native inference event.',
      details: {
        reason: 'mismatched-active-request',
        active: { sessionId: 4, requestId: 41 },
        received: { sessionId: 3, requestId: 41 },
      },
    });
    harness.events.emit(token(4, 41, 0, 'new'));
    expect(harness.getState().messages[1]?.content).toBe('new');
  });
});

describe('SharedInferenceRuntime remount ownership', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('keeps the tuple reachable across detach/remount and uses the new dispatch', async () => {
    let state: ChatState = {
      ...INITIAL_STATE,
      sessionId: 3,
      modelPath: '/verified/model.gguf',
    };
    const native = new FakeNative();
    const events = new FakeEventSource();
    let firstDispatches = 0;
    let secondDispatches = 0;
    const firstBinding = {
      getState: () => state,
      dispatch: (action: ChatAction) => {
        firstDispatches += 1;
        state = chatReducer(state, action);
      },
      resolveModelPath: () => '/verified/model.gguf',
    };
    const runtime = new SharedInferenceRuntime({
      native,
      subscribe: events.subscribe,
      initialBinding: firstBinding,
      makeId: (() => {
        let id = 0;
        return () => `runtime-${String(++id)}`;
      })(),
      watchdogMs: 100,
    });

    const detachFirst = runtime.attach(firstBinding, () => undefined);
    await runtime.submit('prompt').completion;

    const secondBinding = {
      getState: () => state,
      dispatch: (action: ChatAction) => {
        secondDispatches += 1;
        state = chatReducer(state, action);
      },
      resolveModelPath: () => '/verified/model.gguf',
    };
    const detachSecond = runtime.attach(secondBinding, () => undefined);
    const dispatchesAtDetach = firstDispatches;
    // Fast Refresh may attach the replacement before delayed cleanup from the
    // old hook. That cleanup removes only its token, not the newer binding.
    detachFirst();
    expect(events.removeCount).toBe(0);
    expect(runtime.active?.requestId).toBe(41);

    runtime.cancel();
    expect(native.cancelCalls).toEqual([[3, 41]]);
    events.emit(done(3, 41, 'cancelled'));
    expect(runtime.active).toBeNull();
    expect(state.status.kind).toBe('idle');
    expect(firstDispatches).toBe(dispatchesAtDetach);
    expect(secondDispatches).toBeTruthy();

    detachSecond();
    expect(events.removeCount).toBe(1);
    runtime.dispose();
  });

  it('keeps the watchdog and native listener alive while no React binding exists', async () => {
    let state: ChatState = {
      ...INITIAL_STATE,
      sessionId: 3,
      modelPath: '/verified/model.gguf',
    };
    const native = new FakeNative();
    const events = new FakeEventSource();
    const binding = {
      getState: () => state,
      dispatch: (action: ChatAction) => {
        state = chatReducer(state, action);
      },
      resolveModelPath: () => '/verified/model.gguf',
    };
    const runtime = new SharedInferenceRuntime({
      native,
      subscribe: events.subscribe,
      initialBinding: binding,
      makeId: () => 'watchdog-id',
      watchdogMs: 100,
    });
    const detach = runtime.attach(binding, () => undefined);
    await runtime.submit('prompt').completion;
    detach();

    jest.advanceTimersByTime(100);
    expect(native.cancelCalls).toEqual([[3, 41]]);
    expect(runtime.active?.phase).toBe('cancelling');
    expect(events.removeCount).toBe(0);

    events.emit(done(3, 41, 'cancelled'));
    expect(runtime.active).toBeNull();
    expect(events.removeCount).toBe(1);
    expect(runtime.submit('stale callback').admitted).toBe(false);
    runtime.dispose();
  });

  it('restores A when current B detaches, then routes terminal and next submit through A', async () => {
    let state: ChatState = {
      ...INITIAL_STATE,
      sessionId: 3,
      modelPath: '/verified/model.gguf',
    };
    const native = new FakeNative();
    const events = new FakeEventSource();
    let aDispatches = 0;
    let bDispatches = 0;
    const bindingA = {
      getState: () => state,
      dispatch: (action: ChatAction) => {
        aDispatches += 1;
        state = chatReducer(state, action);
      },
      resolveModelPath: () => '/verified/model.gguf',
    };
    const runtime = new SharedInferenceRuntime({
      native,
      subscribe: events.subscribe,
      initialBinding: bindingA,
      makeId: (() => {
        let id = 0;
        return () => `inverse-${String(++id)}`;
      })(),
      watchdogMs: 100,
    });
    const detachA = runtime.attach(bindingA, () => undefined);
    await runtime.submit('first').completion;

    const bindingB = {
      getState: () => state,
      dispatch: (action: ChatAction) => {
        bDispatches += 1;
        state = chatReducer(state, action);
      },
      resolveModelPath: () => '/verified/model.gguf',
    };
    const detachB = runtime.attach(bindingB, () => undefined);
    detachB();
    const aBeforeTerminal = aDispatches;
    const bAtDetach = bDispatches;

    events.emit(token(3, 41, 0, 'answer'));
    events.emit(done(3, 41));
    expect(aDispatches).toBe(aBeforeTerminal + 2);
    expect(bDispatches).toBe(bAtDetach);
    expect(state.status.kind).toBe('idle');

    native.generateImplementation = () => 42;
    const next = runtime.submit('next');
    expect(next.admitted).toBe(true);
    await next.completion;
    expect(native.generateCalls).toHaveLength(2);
    expect(bDispatches).toBe(bAtDetach);
    expect(state.status.kind).toBe('generating');

    events.emit(done(3, 42));
    detachA();
    expect(events.removeCount).toBe(1);
    runtime.dispose();
  });
});

describe('protocol helpers', () => {
  it('rejects bad token counts, lone surrogates, and invalid terminal reasons', () => {
    expect(
      parseInferenceEvent({
        type: 'token',
        sessionId: 1,
        requestId: 1,
        index: 0,
        tokenCount: 0,
        text: 'x',
      }),
    ).toBeNull();
    expect(
      parseInferenceEvent({
        type: 'token',
        sessionId: 1,
        requestId: 1,
        index: 0,
        tokenCount: 1,
        text: '\ud800',
      }),
    ).toBeNull();
    expect(
      parseInferenceEvent({
        type: 'done',
        sessionId: 1,
        requestId: 1,
        reason: 'error',
        stats: DONE_STATS,
      }),
    ).toBeNull();
  });

  it('drops incomplete turns when building a valid native conversation', () => {
    const state: ChatState = {
      ...INITIAL_STATE,
      messages: [
        { id: 'u1', role: 'user', content: 'kept', streaming: false, createdAt: 1 },
        {
          id: 'a1',
          role: 'assistant',
          content: 'answer',
          streaming: false,
          outcome: 'complete',
          createdAt: 2,
        },
        { id: 'u2', role: 'user', content: 'dropped', streaming: false, createdAt: 3 },
        {
          id: 'a2',
          role: 'assistant',
          content: '',
          streaming: false,
          outcome: 'failed',
          createdAt: 4,
        },
      ],
    };
    expect(buildNativeMessages(state, 'new')).toEqual([
      { role: 'user', content: 'kept' },
      { role: 'assistant', content: 'answer' },
      { role: 'user', content: 'new' },
    ]);
  });

  it('uses persisted failed outcomes to omit failed history', () => {
    const state: ChatState = {
      ...INITIAL_STATE,
      status: { kind: 'error', message: 'transport gap' },
      messages: [
        { id: 'u1', role: 'user', content: 'kept', streaming: false, createdAt: 1 },
        {
          id: 'a1',
          role: 'assistant',
          content: 'answer',
          streaming: false,
          outcome: 'complete',
          createdAt: 2,
        },
        { id: 'u2', role: 'user', content: 'failed', streaming: false, createdAt: 3 },
        {
          id: 'a2',
          role: 'assistant',
          content: 'partial',
          streaming: false,
          outcome: 'failed',
          createdAt: 4,
        },
      ],
    };
    expect(buildNativeMessages(state, 'failed')).toEqual([
      { role: 'user', content: 'kept' },
      { role: 'assistant', content: 'answer' },
      { role: 'user', content: 'failed' },
    ]);
  });

  it('reconstructs history from persisted assistant outcomes alone', () => {
    const makeUser = (id: string, content: string, createdAt: number) => ({
      id,
      role: 'user' as const,
      content,
      streaming: false as const,
      createdAt,
    });
    const makeAssistant = (
      id: string,
      content: string,
      outcome: 'complete' | 'cancelled' | 'failed' | 'superseded',
      createdAt: number,
    ) => ({
      id,
      role: 'assistant' as const,
      content,
      streaming: false,
      outcome,
      createdAt,
    });
    const reconstructed: ChatState = {
      ...INITIAL_STATE,
      messages: [
        makeUser('u1', 'keep', 1),
        makeAssistant('a1', 'kept answer', 'complete', 2),
        makeUser('u2', 'cancelled user', 3),
        makeAssistant('a2', 'partial', 'cancelled', 4),
        makeUser('u3', 'failed user', 5),
        makeAssistant('a3', '', 'failed', 6),
        makeUser('u4', 'old branch', 7),
        makeAssistant('a4', 'old answer', 'superseded', 8),
      ],
    };

    expect(buildNativeMessages(reconstructed, 'new turn')).toEqual([
      { role: 'user', content: 'keep' },
      { role: 'assistant', content: 'kept answer' },
      { role: 'user', content: 'new turn' },
    ]);
  });
});
