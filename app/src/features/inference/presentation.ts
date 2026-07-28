import type { BackendDiagnostics } from '../../lib/NativePocketLM';
import type { InferenceErrorCode, Message } from './types';

export type BackendPresentation = {
  label: string;
  detail: string;
  kind: 'metal' | 'cpu' | 'fallback';
};

export function presentBackend(
  diagnostics: BackendDiagnostics,
): BackendPresentation {
  if (diagnostics.selectedAccelerator === 'metal') {
    const layers =
      diagnostics.offloadedLayers < 0
        ? 'layer count unavailable'
        : `${String(diagnostics.offloadedLayers)}/${String(
            diagnostics.modelLayers,
          )} layers offloaded`;
    return {
      label: 'Metal',
      detail: `${layers}; K/Q/V offload ${diagnostics.kqvOffloaded ? 'on' : 'off'}`,
      kind: 'metal',
    };
  }

  if (diagnostics.requestedAccelerator === 'auto') {
    return {
      label: 'CPU fallback',
      detail: 'AUTO did not select Metal; 0 model layers offloaded',
      kind: 'fallback',
    };
  }

  return {
    label: 'CPU',
    detail: 'CPU was requested; 0 model layers offloaded',
    kind: 'cpu',
  };
}

export function presentInferenceError(
  code: InferenceErrorCode | undefined,
  message: string,
): string {
  if (code === 'PROMPT_TOO_LONG') {
    return 'The newest turn is too long for the 2,048-token context after reserving the response budget. Shorten it and try again.';
  }
  if (code === 'METAL_UNAVAILABLE') {
    return `Metal is unavailable for this session. ${message}`;
  }
  return message;
}

export function presentAssistantTerminal(
  message: Extract<Message, { role: 'assistant' }>,
): string | null {
  if (message.outcome === 'streaming') return null;
  if (message.outcome === 'cancelled') return 'Cancelled · ready to regenerate';
  if (message.outcome === 'superseded') return 'Superseded';
  if (message.outcome === 'failed') {
    return message.errorCode === undefined
      ? 'Generation failed'
      : `Generation failed · ${message.errorCode}`;
  }
  if (message.stats === undefined) return 'Complete';
  const timing =
    message.stats.decodeMs > 0
      ? ` · ${String(message.stats.decodeMs)} ms decode`
      : '';
  if (message.finishReason === 'context_exhausted') {
    return (
      `Context exhausted · ${String(message.stats.promptTokens)} prompt + ` +
      `${String(message.stats.generatedTokens)} generated tokens${timing}`
    );
  }
  return `${String(message.stats.generatedTokens)} tokens${timing}`;
}
