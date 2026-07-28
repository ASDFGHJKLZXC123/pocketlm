/**
 * AppContext.tsx
 *
 * React Context + useReducer for all chat/inference state.
 * The reducer is intentionally pure — every side effect (native calls, event
 * subscriptions) lives in features/inference/hooks.ts.
 *
 * App state is intentionally small (loaded model, generation parameters, and
 * streaming state). React Context + useReducer is sufficient; no external
 * state library is needed.
 */

import React, {
  createContext,
  useContext,
  useReducer,
  type ReactNode,
} from 'react';
import type { ChatAction, ChatState, Message } from '../features/inference/types';

// ---------------------------------------------------------------------------
// Initial state
// ---------------------------------------------------------------------------

export const INITIAL_STATE: ChatState = {
  messages: [],
  status: { kind: 'idle' },
  sessionId: null,
  modelPath: null,
  diagnostics: null,
};

// ---------------------------------------------------------------------------
// Reducer
// ---------------------------------------------------------------------------

/**
 * Pure reducer — no side effects, no async logic.
 *
 * Request/session correlation and token ordering are enforced before actions
 * reach this reducer. TOKEN and DONE still retain idempotency guards so a
 * reducer replay cannot mutate an already-finalized message.
 */
export function chatReducer(state: ChatState, action: ChatAction): ChatState {
  switch (action.type) {
    case 'USER_SUBMIT': {
      const userMsg: Message = {
        id: action.messageId,
        role: 'user',
        content: action.content,
        streaming: false,
        createdAt: Date.now(),
      };
      const assistantMsg: Message = {
        id: action.assistantId,
        role: 'assistant',
        content: '',
        streaming: true,
        outcome: 'streaming',
        createdAt: Date.now(),
      };
      return {
        ...state,
        messages: [...state.messages, userMsg, assistantMsg],
        // status stays idle until GENERATION_STARTED (or MODEL_LOADING if lazy
        // load is needed first)
      };
    }

    case 'MODEL_LOADING':
      return { ...state, status: { kind: 'loading' }, diagnostics: null };

    case 'MODEL_READY':
      return {
        ...state,
        sessionId: action.sessionId,
        modelPath: action.modelPath,
        diagnostics: action.diagnostics,
        // Return to idle; GENERATION_STARTED will follow immediately after
        status: { kind: 'idle' },
      };

    case 'GENERATION_STARTED':
      return { ...state, status: { kind: 'generating', requestId: action.requestId } };

    case 'TOKEN': {
      // Append text to the streaming assistant message identified by assistantId.
      // Ignore if the target message is already finalized (out-of-order guard).
      const messages = state.messages.map((msg) => {
        if (msg.id !== action.assistantId) return msg;
        if (msg.role !== 'assistant' || !msg.streaming) return msg;
        return { ...msg, content: msg.content + action.text };
      });
      return { ...state, messages };
    }

    case 'DONE': {
      // Finalize the streaming assistant message; reset status to idle.
      const messages = state.messages.map((msg) => {
        if (msg.id !== action.assistantId) return msg;
        if (msg.role !== 'assistant' || !msg.streaming) return msg;
        return {
          ...msg,
          streaming: false,
          outcome:
            action.reason === 'cancelled'
              ? ('cancelled' as const)
              : ('complete' as const),
          finishReason: action.reason,
          stats: action.stats,
        };
      });
      return { ...state, messages, status: { kind: 'idle' } };
    }

    case 'ERROR': {
      // Finalize any in-progress assistant message with semantic error data.
      // If assistantId is provided, only that message is touched; otherwise
      // we sweep all streaming messages (defensive for unexpected states).
      const messages = state.messages.map((msg) => {
        if (msg.role !== 'assistant' || !msg.streaming) return msg;
        if (action.assistantId !== undefined && msg.id !== action.assistantId) return msg;
        return {
          ...msg,
          streaming: false,
          outcome: 'failed' as const,
          errorCode: action.code,
          errorMessage: action.message,
        };
      });
      return {
        ...state,
        messages,
        status: { kind: 'error', message: action.message, code: action.code },
      };
    }

    case 'SUPERSEDE_ASSISTANT': {
      const messages = state.messages.map((msg) => {
        if (
          msg.role !== 'assistant' ||
          msg.id !== action.assistantId ||
          msg.streaming
        ) {
          return msg;
        }
        return { ...msg, outcome: 'superseded' as const };
      });
      return { ...state, messages };
    }

    case 'CANCEL': {
      // Cancellation is a request, not a terminal. Native still owns the
      // request until its matching DONE/ERROR event (or awaited unload), so
      // streaming state and the generating status must remain intact.
      return state;
    }

    case 'RESET':
      return INITIAL_STATE;

    default: {
      // Exhaustive check — assigning to `never` forces a compile error if a
      // new ChatAction variant is added without a corresponding case.
      const _exhaustive: never = action;
      void _exhaustive;
      return state;
    }
  }
}

// ---------------------------------------------------------------------------
// Context creation
// ---------------------------------------------------------------------------

const AppStateContext = createContext<ChatState | undefined>(undefined);
const AppDispatchContext = createContext<React.Dispatch<ChatAction> | undefined>(undefined);

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

interface AppProviderProps {
  children: ReactNode;
}

export function AppProvider({ children }: AppProviderProps): React.JSX.Element {
  const [state, dispatch] = useReducer(chatReducer, INITIAL_STATE);

  return (
    <AppStateContext.Provider value={state}>
      <AppDispatchContext.Provider value={dispatch}>
        {children}
      </AppDispatchContext.Provider>
    </AppStateContext.Provider>
  );
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/**
 * Returns the current ChatState.  Must be used inside <AppProvider>.
 */
export function useAppState(): ChatState {
  const ctx = useContext(AppStateContext);
  if (ctx === undefined) {
    throw new Error('useAppState must be used within an AppProvider');
  }
  return ctx;
}

/**
 * Returns the dispatch function.  Must be used inside <AppProvider>.
 */
export function useAppDispatch(): React.Dispatch<ChatAction> {
  const ctx = useContext(AppDispatchContext);
  if (ctx === undefined) {
    throw new Error('useAppDispatch must be used within an AppProvider');
  }
  return ctx;
}
