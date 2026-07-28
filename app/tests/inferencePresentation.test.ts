import {
  presentAssistantTerminal,
  presentBackend,
  presentInferenceError,
} from '../src/features/inference/presentation';

describe('inference presentation', () => {
  it('makes AUTO CPU fallback explicit', () => {
    expect(
      presentBackend({
        requestedAccelerator: 'auto',
        selectedAccelerator: 'cpu',
        contextSize: 2048,
        batchSize: 512,
        modelLayers: 24,
        offloadedLayers: 0,
        kqvOffloaded: false,
        peakRssBytes: 0,
      }),
    ).toEqual({
      label: 'CPU fallback',
      detail: 'AUTO did not select Metal; 0 model layers offloaded',
      kind: 'fallback',
    });
  });

  it('does not misreport an unavailable Metal layer count as zero', () => {
    const value = presentBackend({
      requestedAccelerator: 'auto',
      selectedAccelerator: 'metal',
      contextSize: 2048,
      batchSize: 512,
      modelLayers: 24,
      offloadedLayers: -1,
      kqvOffloaded: true,
      peakRssBytes: 0,
    });
    expect(value.label).toBe('Metal');
    expect(value.detail).toContain('layer count unavailable');
  });

  it('gives prompt overflow stable, actionable copy', () => {
    expect(presentInferenceError('PROMPT_TOO_LONG', 'native detail')).toMatch(
      /Shorten it/,
    );
  });

  it('surfaces context exhaustion and native token statistics', () => {
    const text = presentAssistantTerminal({
      id: 'assistant',
      role: 'assistant',
      content: 'answer',
      streaming: false,
      outcome: 'complete',
      finishReason: 'context_exhausted',
      stats: {
        prefillMs: 10,
        decodeMs: 20,
        promptTokens: 1800,
        generatedTokens: 248,
        peakRssBytes: 1,
      },
      createdAt: 1,
    });
    expect(text).toContain('Context exhausted');
    expect(text).toContain('1800 prompt + 248 generated');
  });
});
