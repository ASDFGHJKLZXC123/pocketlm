import type {
  BackendDiagnostics,
  Spec as NativePocketLMSpec,
} from '../../lib/NativePocketLM';
import type {
  ActiveRequest,
  ChatAction,
  ChatState,
  GenerationParams,
  InferenceErrorCode,
  InferenceEvent,
} from './types';

const MAX_INT32 = 2_147_483_647;

export const DEFAULT_GENERATION_PARAMS: GenerationParams = {
  maxTokens: 256,
  temperature: 0.7,
  topK: 40,
  topP: 0.9,
  seed: -1,
  nThreads: 0,
};

export const DEFAULT_SESSION_CONFIG = {
  contextSize: 2048,
  accelerator: 'auto' as const,
  gpuLayers: 0,
};

export const DEFAULT_WATCHDOG_MS = 120_000;

export type NativeInferenceModule = Pick<
  NativePocketLMSpec,
  'loadModel' | 'unloadModel' | 'generate' | 'cancel' | 'getDiagnostics'
>;

export type InferenceSubscription = { remove: () => void };

export type CoordinatorControlState = {
  activePhase: ActiveRequest['phase'] | null;
  busy: boolean;
  resetting: boolean;
};

export type Submission = {
  admitted: boolean;
  completion: Promise<void>;
};

export type DiscardedInferenceEventDiagnostic = {
  reason: 'no-active-request' | 'invalid-identity' | 'mismatched-active-request';
  active: EventIdentity | null;
  received: EventIdentity | null;
};

type ActiveMetadata = {
  cancelSent: boolean;
  faulted: boolean;
};

export interface InferenceCoordinatorDependencies {
  native: NativeInferenceModule;
  subscribe: (listener: (event: unknown) => void) => InferenceSubscription;
  getState: () => ChatState;
  dispatch: (action: ChatAction) => void;
  resolveModelPath: () => string;
  makeId: () => string;
  reportError?: (error: unknown) => void;
  reportDiagnostic?: (
    message: string,
    details: DiscardedInferenceEventDiagnostic,
  ) => void;
  onControlState?: (state: CoordinatorControlState) => void;
  watchdogMs?: number;
}

const ERROR_CODES: ReadonlySet<InferenceErrorCode> = new Set([
  'INVALID_ARGUMENT',
  'OOM',
  'MODEL_LOAD_FAILED',
  'CONTEXT_CREATE_FAILED',
  'METAL_UNAVAILABLE',
  'CHAT_TEMPLATE_FAILED',
  'TOKENIZE_FAILED',
  'PROMPT_TOO_LONG',
  'DECODE_FAILED',
  'INTERNAL',
]);

function isPositiveInt32(value: unknown): value is number {
  return (
    typeof value === 'number' &&
    Number.isInteger(value) &&
    value > 0 &&
    value <= MAX_INT32
  );
}

function isNonNegativeSafeInteger(value: unknown): value is number {
  return (
    typeof value === 'number' &&
    Number.isSafeInteger(value) &&
    value >= 0
  );
}

function isFiniteNonNegative(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0;
}

/** JavaScript strings can contain lone surrogates, which are not valid UTF-8 text. */
function isUnicodeScalarString(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= value.length) return false;
      const next = value.charCodeAt(index + 1);
      if (next < 0xdc00 || next > 0xdfff) return false;
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

type EventIdentity = { sessionId: number; requestId: number };

function readEventIdentity(raw: unknown): EventIdentity | null {
  if (typeof raw !== 'object' || raw === null) return null;
  const record = raw as Record<string, unknown>;
  if (!isPositiveInt32(record['sessionId'])) return null;
  if (!isPositiveInt32(record['requestId'])) return null;
  return {
    sessionId: record['sessionId'],
    requestId: record['requestId'],
  };
}

export function parseInferenceEvent(raw: unknown): InferenceEvent | null {
  const identity = readEventIdentity(raw);
  if (identity === null) return null;

  const record = raw as Record<string, unknown>;
  switch (record['type']) {
    case 'token': {
      const index = record['index'];
      const tokenCount = record['tokenCount'];
      const text = record['text'];
      if (!isNonNegativeSafeInteger(index)) return null;
      if (!isPositiveInt32(tokenCount)) return null;
      if (index + tokenCount > Number.MAX_SAFE_INTEGER) return null;
      if (
        typeof text !== 'string' ||
        text.length === 0 ||
        !isUnicodeScalarString(text)
      ) {
        return null;
      }
      return { type: 'token', ...identity, index, tokenCount, text };
    }

    case 'done': {
      const reason = record['reason'];
      if (
        reason !== 'eos' &&
        reason !== 'max_tokens' &&
        reason !== 'cancelled' &&
        reason !== 'context_exhausted'
      ) {
        return null;
      }
      const rawStats = record['stats'];
      if (typeof rawStats !== 'object' || rawStats === null) return null;
      const stats = rawStats as Record<string, unknown>;
      if (!isFiniteNonNegative(stats['prefillMs'])) return null;
      if (!isFiniteNonNegative(stats['decodeMs'])) return null;
      if (!isNonNegativeSafeInteger(stats['promptTokens'])) return null;
      if (!isNonNegativeSafeInteger(stats['generatedTokens'])) return null;
      if (!isNonNegativeSafeInteger(stats['peakRssBytes'])) return null;
      return {
        type: 'done',
        ...identity,
        reason,
        stats: {
          prefillMs: stats['prefillMs'],
          decodeMs: stats['decodeMs'],
          promptTokens: stats['promptTokens'],
          generatedTokens: stats['generatedTokens'],
          peakRssBytes: stats['peakRssBytes'],
        },
      };
    }

    case 'error': {
      const code = record['code'];
      const message = record['message'];
      if (typeof code !== 'string' || !ERROR_CODES.has(code as InferenceErrorCode)) {
        return null;
      }
      if (
        typeof message !== 'string' ||
        message.length === 0 ||
        !isUnicodeScalarString(message)
      ) {
        return null;
      }
      return {
        type: 'error',
        ...identity,
        code: code as InferenceErrorCode,
        message,
      };
    }

    default:
      return null;
  }
}

function errorMessage(error: unknown): string {
  if (error instanceof Error && error.message.length > 0) return error.message;
  if (typeof error === 'object' && error !== null) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === 'string' && message.length > 0) return message;
  }
  return String(error);
}

function inferenceErrorCode(error: unknown): InferenceErrorCode | undefined {
  if (typeof error !== 'object' || error === null) return undefined;
  const code = (error as { code?: unknown }).code;
  return typeof code === 'string' && ERROR_CODES.has(code as InferenceErrorCode)
    ? (code as InferenceErrorCode)
    : undefined;
}

function rejectionMessage(result: number): string {
  switch (result) {
    case -1:
      return 'Native generation rejected invalid input.';
    case -2:
      return 'Native generation is already busy.';
    case -3:
      return 'The native session is shutting down.';
    case -4:
      return 'Native generation could not copy the request.';
    case -5:
      return 'The native request ID space is exhausted.';
    default:
      return `Native generation returned invalid request ID ${String(result)}.`;
  }
}

/**
 * Keep only complete, successful user/assistant turns, then append the newest
 * user prompt. The coordinator supplies semantic IDs for failed/cancelled
 * attempts, so history filtering never depends on rendered "[error]" text.
 */
export function buildNativeMessages(
  state: ChatState,
  prompt: string,
): { role: 'user' | 'assistant'; content: string }[] {
  const messages: { role: 'user' | 'assistant'; content: string }[] = [];
  for (let index = 0; index + 1 < state.messages.length; index += 2) {
    const user = state.messages[index];
    const assistant = state.messages[index + 1];
    if (
      user?.role === 'user' &&
      assistant?.role === 'assistant' &&
      !user.streaming &&
      !assistant.streaming &&
      assistant.outcome === 'complete' &&
      user.content.length > 0 &&
      assistant.content.length > 0
    ) {
      messages.push(
        { role: 'user', content: user.content },
        { role: 'assistant', content: assistant.content },
      );
    }
  }
  messages.push({ role: 'user', content: prompt });
  return messages;
}

type RegeneratableTurn = {
  prompt: string;
  assistantId: string;
};

function findRegeneratableTurn(state: ChatState): RegeneratableTurn | null {
  for (let index = state.messages.length - 2; index >= 0; index -= 1) {
    const user = state.messages[index];
    const assistant = state.messages[index + 1];
    if (
      user?.role === 'user' &&
      assistant?.role === 'assistant' &&
      !assistant.streaming &&
      assistant.outcome !== 'superseded' &&
      user.content.trim().length > 0
    ) {
      return { prompt: user.content, assistantId: assistant.id };
    }
  }
  return null;
}

function stateWithSupersededAssistant(
  state: ChatState,
  assistantId: string,
): ChatState {
  return {
    ...state,
    messages: state.messages.map((message) =>
      message.role === 'assistant' && message.id === assistantId
        ? { ...message, streaming: false, outcome: 'superseded' as const }
        : message,
    ),
  };
}

export class InferenceCoordinator {
  private readonly native: NativeInferenceModule;
  private readonly subscribeToEvents: InferenceCoordinatorDependencies['subscribe'];
  private readonly getState: InferenceCoordinatorDependencies['getState'];
  private readonly dispatch: InferenceCoordinatorDependencies['dispatch'];
  private readonly resolveModelPath: InferenceCoordinatorDependencies['resolveModelPath'];
  private readonly makeId: InferenceCoordinatorDependencies['makeId'];
  private readonly reportError: NonNullable<
    InferenceCoordinatorDependencies['reportError']
  >;
  private readonly reportDiagnostic: NonNullable<
    InferenceCoordinatorDependencies['reportDiagnostic']
  >;
  private readonly onControlState: NonNullable<
    InferenceCoordinatorDependencies['onControlState']
  >;
  private readonly watchdogMs: number;

  private subscription: InferenceSubscription | null = null;
  private activeRequest: ActiveRequest | null = null;
  private activeMetadata: ActiveMetadata | null = null;
  private submissionLocked = false;
  private submitCallInProgress = false;
  private submissionUnlockDeferred = false;
  private resetting = false;
  private sessionId: number | null;
  private modelPath: string | null;
  private diagnostics: BackendDiagnostics | null;
  private loadPromise: Promise<number> | null = null;
  private diagnosticsCleanupPromise: Promise<void> | null = null;
  private resetPromise: Promise<void> | null = null;
  private acceptingRequest = false;
  private queuedGenerateEvents: unknown[] = [];
  private watchdog: ReturnType<typeof setTimeout> | null = null;
  private retryPrompt: string | null = null;

  constructor(dependencies: InferenceCoordinatorDependencies) {
    this.native = dependencies.native;
    this.subscribeToEvents = dependencies.subscribe;
    this.getState = dependencies.getState;
    this.dispatch = dependencies.dispatch;
    this.resolveModelPath = dependencies.resolveModelPath;
    this.makeId = dependencies.makeId;
    this.reportError = dependencies.reportError ?? (() => undefined);
    this.reportDiagnostic =
      dependencies.reportDiagnostic ??
      ((message, details) => console.warn(message, details));
    this.onControlState = dependencies.onControlState ?? (() => undefined);
    this.watchdogMs = dependencies.watchdogMs ?? DEFAULT_WATCHDOG_MS;

    if (!Number.isFinite(this.watchdogMs) || this.watchdogMs <= 0) {
      throw new Error('watchdogMs must be a positive finite number');
    }

    const initialState = this.getState();
    this.sessionId = isPositiveInt32(initialState.sessionId)
      ? initialState.sessionId
      : null;
    this.modelPath = initialState.modelPath;
    this.diagnostics = initialState.diagnostics;
  }

  start(): void {
    if (this.subscription !== null) return;
    this.subscription = this.subscribeToEvents((event) => this.handleEvent(event));
    if (this.activeRequest !== null) this.armWatchdog();
  }

  stop(): void {
    this.subscription?.remove();
    this.subscription = null;
    this.clearWatchdog();
  }

  get active(): Readonly<ActiveRequest> | null {
    return this.activeRequest;
  }

  get controlState(): CoordinatorControlState {
    return {
      activePhase: this.activeRequest?.phase ?? null,
      busy: this.submissionLocked || this.activeRequest !== null || this.resetting,
      resetting: this.resetting,
    };
  }

  get canRetry(): boolean {
    return (
      !this.controlState.busy &&
      this.retryPrompt !== null &&
      this.getState().status.kind === 'error'
    );
  }

  get canRegenerate(): boolean {
    return (
      !this.controlState.busy &&
      findRegeneratableTurn(this.getState()) !== null
    );
  }

  submit(rawPrompt: string): Submission {
    const prompt = rawPrompt.trim();
    if (prompt.length === 0) {
      return { admitted: false, completion: Promise.resolve() };
    }

    return this.beginSubmission(prompt, this.getState(), null);
  }

  regenerate(): Submission {
    const state = this.getState();
    const turn = findRegeneratableTurn(state);
    if (turn === null) {
      return { admitted: false, completion: Promise.resolve() };
    }
    return this.beginSubmission(turn.prompt, state, turn.assistantId);
  }

  private beginSubmission(
    prompt: string,
    state: ChatState,
    supersededAssistantId: string | null,
  ): Submission {
    if (
      this.submissionLocked ||
      this.activeRequest !== null ||
      this.resetting ||
      state.status.kind === 'loading' ||
      state.status.kind === 'generating'
    ) {
      return { admitted: false, completion: Promise.resolve() };
    }

    // This lock is deliberately set before the first dispatch, native call, or
    // await so two submissions in the same JavaScript turn cannot overlap.
    this.submissionLocked = true;
    this.retryPrompt = prompt;
    this.publishControlState();

    let historyState = state;
    if (supersededAssistantId !== null) {
      this.dispatch({
        type: 'SUPERSEDE_ASSISTANT',
        assistantId: supersededAssistantId,
      });
      // React dispatch is not synchronously reflected through getState(). Use
      // the same pure projection for this submission so the superseded branch
      // cannot leak into the native history in the dispatch-to-render window.
      historyState = stateWithSupersededAssistant(
        state,
        supersededAssistantId,
      );
    }

    const messageId = this.makeId();
    const assistantId = this.makeId();
    this.dispatch({
      type: 'USER_SUBMIT',
      content: prompt,
      messageId,
      assistantId,
    });

    // An already-loaded native call may reject, throw, or (if faulty) deliver
    // a synchronous terminal before performSubmission() first suspends. Keep
    // the lock through submit()'s return and release it in the next microtask
    // so a second call in this JavaScript turn is still excluded.
    this.submitCallInProgress = true;
    let completion!: Promise<void>;
    try {
      completion = this.performSubmission(historyState, prompt, assistantId);
    } finally {
      this.submitCallInProgress = false;
      if (this.submissionUnlockDeferred) {
        this.submissionUnlockDeferred = false;
        void Promise.resolve().then(() => this.releaseSubmissionLock());
      }
    }

    return { admitted: true, completion };
  }

  private async performSubmission(
    state: ChatState,
    prompt: string,
    assistantId: string,
  ): Promise<void> {
    try {
      let sessionId = this.sessionId;
      if (sessionId === null && isPositiveInt32(state.sessionId)) {
        sessionId = state.sessionId;
        this.sessionId = sessionId;
        this.modelPath = state.modelPath;
        this.diagnostics = state.diagnostics;
      }

      if (sessionId === null) {
        const modelPath = this.resolveModelPath();
        this.dispatch({ type: 'MODEL_LOADING' });
        const pendingLoad = this.native.loadModel(modelPath, DEFAULT_SESSION_CONFIG);
        this.loadPromise = pendingLoad;
        try {
          sessionId = await pendingLoad;
        } finally {
          if (this.loadPromise === pendingLoad) this.loadPromise = null;
        }

        if (!isPositiveInt32(sessionId)) {
          throw new Error(`Native load returned invalid session ID ${String(sessionId)}.`);
        }
        this.sessionId = sessionId;
        this.modelPath = modelPath;
      }

      if (this.diagnostics === null) {
        const modelPath = this.modelPath ?? state.modelPath;
        if (modelPath === null) {
          throw new Error('A loaded native session has no model path.');
        }
        const ready = await this.establishDiagnostics(
          sessionId,
          modelPath,
          assistantId,
        );
        if (!ready) return;
      }

      // Reset owns the lock once requested. It unloads the newly-created
      // session and clears state only after native destruction completes.
      if (this.resetting) return;

      const nativeMessages = buildNativeMessages(state, prompt);
      this.acceptingRequest = true;
      this.queuedGenerateEvents = [];
      let requestId: number;
      try {
        requestId = this.native.generate(
          sessionId,
          nativeMessages,
          DEFAULT_GENERATION_PARAMS,
        );
      } finally {
        this.acceptingRequest = false;
      }

      if (!isPositiveInt32(requestId)) {
        this.queuedGenerateEvents = [];
        this.failLocally(rejectionMessage(requestId), assistantId);
        this.releaseSubmissionLock();
        return;
      }

      this.activeRequest = {
        sessionId,
        requestId,
        assistantId,
        expectedTokenIndex: 0,
        phase: 'starting',
      };
      this.activeMetadata = { cancelSent: false, faulted: false };
      this.publishControlState();

      this.dispatch({ type: 'GENERATION_STARTED', requestId });
      if (this.activeRequest?.phase === 'starting') {
        this.activeRequest.phase = 'generating';
      }
      this.publishControlState();
      this.armWatchdog();

      // A conforming bridge schedules delivery for a later JavaScript turn.
      // Buffering here also keeps correlation safe if a test double or faulty
      // bridge invokes the listener while generate() is still on the stack.
      const queuedEvents = this.queuedGenerateEvents;
      this.queuedGenerateEvents = [];
      for (const event of queuedEvents) this.handleEvent(event);
    } catch (error: unknown) {
      this.queuedGenerateEvents = [];
      if (this.resetting) return;
      this.failLocally(
        errorMessage(error),
        assistantId,
        error,
        inferenceErrorCode(error),
      );
      this.releaseSubmissionLock();
    }
  }

  private async establishDiagnostics(
    sessionId: number,
    modelPath: string,
    assistantId: string,
  ): Promise<boolean> {
    try {
      const diagnostics = await this.native.getDiagnostics(sessionId);
      if (this.resetting) return false;
      this.diagnostics = diagnostics;
      this.dispatch({
        type: 'MODEL_READY',
        sessionId,
        modelPath,
        diagnostics,
      });
      return true;
    } catch (error: unknown) {
      if (this.resetting) return false;

      let cleanupError: unknown;
      try {
        const cleanup = this.native.unloadModel(sessionId);
        this.diagnosticsCleanupPromise = cleanup;
        try {
          await cleanup;
        } finally {
          if (this.diagnosticsCleanupPromise === cleanup) {
            this.diagnosticsCleanupPromise = null;
          }
        }
        if (this.sessionId === sessionId) {
          this.sessionId = null;
          this.modelPath = null;
          this.diagnostics = null;
        }
      } catch (unloadError: unknown) {
        cleanupError = unloadError;
      }

      if (this.resetting) return false;

      const diagnosticMessage = `Unable to read native backend diagnostics: ${errorMessage(error)}`;
      const message =
        cleanupError === undefined
          ? diagnosticMessage
          : `${diagnosticMessage}. Cleanup also failed: ${errorMessage(cleanupError)}`;
      this.failLocally(
        message,
        assistantId,
        error,
        inferenceErrorCode(error),
      );
      this.releaseSubmissionLock();
      return false;
    }
  }

  retry(): Submission {
    const prompt = this.retryPrompt;
    if (!this.canRetry || prompt === null) {
      return { admitted: false, completion: Promise.resolve() };
    }
    return this.submit(prompt);
  }

  cancel(): void {
    const active = this.activeRequest;
    if (active === null || active.phase === 'cancelling') return;
    active.phase = 'cancelling';
    this.dispatch({ type: 'CANCEL' });
    this.publishControlState();
    this.sendCancelOnce();
    this.armWatchdog();
  }

  reset(): Promise<void> {
    if (this.resetPromise !== null) return this.resetPromise;
    const pending = this.performReset();
    this.resetPromise = pending.finally(() => {
      this.resetPromise = null;
    });
    return this.resetPromise;
  }

  handleEvent(raw: unknown): void {
    if (this.acceptingRequest) {
      this.queuedGenerateEvents.push(raw);
      return;
    }

    const identity = readEventIdentity(raw);
    const active = this.activeRequest;
    if (active === null) {
      this.logDiscardedEvent('no-active-request', identity, null);
      return;
    }
    const activeIdentity = {
      sessionId: active.sessionId,
      requestId: active.requestId,
    };
    if (identity === null) {
      this.logDiscardedEvent('invalid-identity', null, activeIdentity);
      return;
    }
    if (
      identity.sessionId !== active.sessionId ||
      identity.requestId !== active.requestId
    ) {
      this.logDiscardedEvent('mismatched-active-request', identity, activeIdentity);
      return;
    }

    const event = parseInferenceEvent(raw);
    if (event === null) {
      this.failTransport('Native emitted a malformed inference event.');
      return;
    }

    switch (event.type) {
      case 'token':
        this.handleToken(event);
        return;
      case 'done':
        this.handleDone(event);
        return;
      case 'error':
        this.handleNativeError(event);
        return;
    }
  }

  private logDiscardedEvent(
    reason: DiscardedInferenceEventDiagnostic['reason'],
    received: EventIdentity | null,
    active: EventIdentity | null,
  ): void {
    this.reportDiagnostic('Discarded stale native inference event.', {
      reason,
      active,
      received,
    });
  }

  private handleToken(event: Extract<InferenceEvent, { type: 'token' }>): void {
    const active = this.activeRequest;
    if (active === null || active.phase === 'cancelling') return;

    const expected = active.expectedTokenIndex;
    if (event.index < expected) {
      return;
    }
    if (event.index > expected) {
      this.failTransport(
        `Inference token gap: expected index ${String(expected)}, received ` +
          `${String(event.index)}.`,
      );
      return;
    }

    const eventEnd = event.index + event.tokenCount;
    active.expectedTokenIndex = eventEnd;
    this.dispatch({
      type: 'TOKEN',
      assistantId: active.assistantId,
      text: event.text,
    });
    this.armWatchdog();
  }

  private handleDone(event: Extract<InferenceEvent, { type: 'done' }>): void {
    const active = this.activeRequest;
    const metadata = this.activeMetadata;
    if (active === null || metadata === null) return;

    if (!metadata.faulted) {
      this.dispatch({
        type: 'DONE',
        assistantId: active.assistantId,
        reason: event.reason,
        stats: event.stats,
      });
    }
    this.releaseNativeOwnership();
  }

  private handleNativeError(event: Extract<InferenceEvent, { type: 'error' }>): void {
    const active = this.activeRequest;
    const metadata = this.activeMetadata;
    if (active === null || metadata === null) return;

    if (!metadata.faulted) {
      this.failLocally(
        event.message,
        active.assistantId,
        new Error(event.message),
        event.code,
      );
    }
    this.releaseNativeOwnership();
  }

  private failTransport(message: string): void {
    const active = this.activeRequest;
    const metadata = this.activeMetadata;
    if (active === null || metadata === null || metadata.faulted) return;

    metadata.faulted = true;
    active.phase = 'cancelling';
    const error = new Error(message);
    this.reportError(error);
    this.dispatch({ type: 'ERROR', message, assistantId: active.assistantId });
    this.publishControlState();
    this.sendCancelOnce();
    this.armWatchdog();
  }

  private failLocally(
    message: string,
    assistantId: string,
    cause?: unknown,
    code?: InferenceErrorCode,
  ): void {
    this.reportError(cause ?? new Error(message));
    this.dispatch({ type: 'ERROR', message, code, assistantId });
    this.publishControlState();
  }

  private sendCancelOnce(): void {
    const active = this.activeRequest;
    const metadata = this.activeMetadata;
    if (active === null || metadata === null || metadata.cancelSent) return;
    metadata.cancelSent = true;
    try {
      this.native.cancel(active.sessionId, active.requestId);
    } catch (error: unknown) {
      if (!metadata.faulted) {
        metadata.faulted = true;
        const message = `Native cancellation failed: ${errorMessage(error)}`;
        this.reportError(error);
        this.dispatch({
          type: 'ERROR',
          message,
          code: inferenceErrorCode(error),
          assistantId: active.assistantId,
        });
      }
    }
  }

  private armWatchdog(): void {
    this.clearWatchdog();
    if (this.subscription === null || this.activeRequest === null) return;
    const { sessionId, requestId } = this.activeRequest;
    this.watchdog = setTimeout(() => {
      const active = this.activeRequest;
      if (
        active === null ||
        active.sessionId !== sessionId ||
        active.requestId !== requestId
      ) {
        return;
      }
      this.failTransport(
        `Inference watchdog expired after ${String(this.watchdogMs)} ms.`,
      );
    }, this.watchdogMs);
  }

  private clearWatchdog(): void {
    if (this.watchdog !== null) clearTimeout(this.watchdog);
    this.watchdog = null;
  }

  private releaseNativeOwnership(): void {
    this.clearWatchdog();
    this.activeRequest = null;
    this.activeMetadata = null;
    this.publishControlState();
    if (!this.resetting) this.releaseSubmissionLock();
  }

  private releaseSubmissionLock(): void {
    if (this.resetting) return;
    if (this.submitCallInProgress) {
      this.submissionUnlockDeferred = true;
      return;
    }
    this.submissionLocked = false;
    this.publishControlState();
  }

  private async performReset(): Promise<void> {
    this.resetting = true;
    this.submissionLocked = true;
    this.publishControlState();

    const pendingLoad = this.loadPromise;
    if (pendingLoad !== null) {
      try {
        await pendingLoad;
      } catch {
        // A rejected load owns no session; submit() reports the original error.
      }
    }

    const pendingDiagnosticsCleanup = this.diagnosticsCleanupPromise;
    if (pendingDiagnosticsCleanup !== null) {
      try {
        await pendingDiagnosticsCleanup;
      } catch {
        // The reset path retries unload below while retaining the session ID.
      }
    }

    if (this.activeRequest !== null) {
      this.activeRequest.phase = 'cancelling';
      this.publishControlState();
      this.sendCancelOnce();
    }

    let sessionId = this.sessionId;
    if (sessionId === null) {
      const stateSessionId = this.getState().sessionId;
      if (isPositiveInt32(stateSessionId)) sessionId = stateSessionId;
    }

    if (sessionId !== null) {
      try {
        await this.native.unloadModel(sessionId);
      } catch (error: unknown) {
        const active = this.activeRequest;
        if (active !== null && this.activeMetadata !== null) {
          this.activeMetadata.faulted = true;
        }
        const message = `Unable to reset the native session: ${errorMessage(error)}`;
        this.reportError(error);
        this.dispatch({
          type: 'ERROR',
          message,
          code: inferenceErrorCode(error),
          assistantId: active?.assistantId,
        });
        // The session may still own native work. Keep the exclusion lock and
        // tuple so a later matching terminal or another reset can recover.
        this.resetting = false;
        this.publishControlState();
        return;
      }
    }

    // unloadModel resolves only after terminal delivery and destruction. It is
    // therefore the second safe ownership-clear boundary after a terminal.
    this.clearWatchdog();
    this.activeRequest = null;
    this.activeMetadata = null;
    this.sessionId = null;
    this.modelPath = null;
    this.diagnostics = null;
    this.retryPrompt = null;
    this.submissionLocked = false;
    this.resetting = false;
    this.dispatch({ type: 'RESET' });
    this.publishControlState();
  }

  private publishControlState(): void {
    this.onControlState(this.controlState);
  }
}
