import type { BackendDiagnostics } from '../../lib/NativePocketLM';

/**
 * GenerationParams mirrors the `params` object in Spec.generate() so consumers
 * can type their arguments without importing from the native spec directly.
 */
export type GenerationParams = {
  maxTokens: number;
  temperature: number;
  topK: number;
  topP: number;
  seed: number;
  nThreads: number;
};

export type ActiveRequest = {
  sessionId: number;
  requestId: number;
  assistantId: string;
  expectedTokenIndex: number;
  phase: 'starting' | 'generating' | 'cancelling';
};

export type InferenceErrorCode =
  | 'INVALID_ARGUMENT'
  | 'OOM'
  | 'MODEL_LOAD_FAILED'
  | 'CONTEXT_CREATE_FAILED'
  | 'METAL_UNAVAILABLE'
  | 'CHAT_TEMPLATE_FAILED'
  | 'TOKENIZE_FAILED'
  | 'PROMPT_TOO_LONG'
  | 'DECODE_FAILED'
  | 'INTERNAL';

export type FinishReason =
  | 'eos'
  | 'max_tokens'
  | 'cancelled'
  | 'context_exhausted';

export type GenerationStats = {
  prefillMs: number;
  decodeMs: number;
  promptTokens: number;
  generatedTokens: number;
  peakRssBytes: number;
};

/**
 * InferenceEvent — frozen v2 union for every payload emitted on the normative
 * `onInferenceEvent` RCTEventEmitter / NativeEventEmitter channel.
 */
export type InferenceEvent =
  | {
      type: 'token';
      sessionId: number;
      requestId: number;
      index: number; // first contiguous C fragment represented
      tokenCount: number; // number of contiguous C fragments, >= 1
      text: string; // non-empty valid UTF-8 fragment
    }
  | {
      type: 'done';
      sessionId: number;
      requestId: number;
      reason: FinishReason;
      stats: GenerationStats;
    }
  | {
      type: 'error';
      sessionId: number;
      requestId: number;
      code: InferenceErrorCode;
      message: string;
    };

// ---------------------------------------------------------------------------
// Chat-layer types
// ---------------------------------------------------------------------------

/**
 * A single message in the conversation.
 * `content` accumulates as tokens arrive; `streaming` is true for the assistant
 * message currently being generated.
 */
type MessageBase = {
  id: string; // caller-assigned (nanoid-style)
  content: string; // accumulated text; empty string valid while streaming
  createdAt: number; // Date.now() on creation
};

export type AssistantOutcome =
  | 'streaming'
  | 'complete'
  | 'cancelled'
  | 'failed'
  | 'superseded';

export type Message =
  | (MessageBase & {
      role: 'user';
      streaming: false;
    })
  | (MessageBase & {
      role: 'assistant';
      streaming: boolean;
      outcome: AssistantOutcome;
      finishReason?: FinishReason;
      stats?: GenerationStats;
      errorCode?: InferenceErrorCode;
      errorMessage?: string;
    });

/**
 * Coarse status of the inference subsystem.
 * The UI consults this to decide what controls to render.
 */
export type InferenceStatus =
  | { kind: 'idle' }
  | { kind: 'loading' } // model is loading
  | { kind: 'generating'; requestId: number } // decode in progress
  | { kind: 'error'; message: string; code?: InferenceErrorCode };

/** Top-level shape stored in AppContext. */
export type ChatState = {
  messages: Message[];
  status: InferenceStatus;
  sessionId: number | null;
  modelPath: string | null;
  diagnostics: BackendDiagnostics | null;
};

/** Every action the useReducer in AppContext handles. */
export type ChatAction =
  | { type: 'USER_SUBMIT'; content: string; messageId: string; assistantId: string }
  | { type: 'MODEL_LOADING' }
  | {
      type: 'MODEL_READY';
      sessionId: number;
      modelPath: string;
      diagnostics: BackendDiagnostics;
    }
  | { type: 'GENERATION_STARTED'; requestId: number }
  | { type: 'TOKEN'; assistantId: string; text: string }
  | {
      type: 'DONE';
      assistantId: string;
      reason: FinishReason;
      stats: GenerationStats;
    }
  | {
      type: 'ERROR';
      message: string;
      code?: InferenceErrorCode;
      assistantId?: string;
    }
  | { type: 'SUPERSEDE_ASSISTANT'; assistantId: string }
  | { type: 'CANCEL' }
  | { type: 'RESET' };
