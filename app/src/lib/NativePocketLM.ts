import type { CodegenTypes, TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export const INFERENCE_EVENT_NAME = 'onInferenceEvent' as const;

export type Accelerator = 'auto' | 'cpu' | 'metal';

// Native session and accepted-request IDs are positive Int32 values. Zero is
// invalid; a negative generate result is a synchronous rejection and emits no
// event. The exact mapping is frozen in INFERENCE_PROTOCOL_V2.md.

export type SessionConfig = {
  contextSize: CodegenTypes.Int32;
  accelerator: Accelerator;
  gpuLayers: CodegenTypes.Int32;
};

export type NativeChatMessage = {
  role: 'system' | 'user' | 'assistant';
  content: string;
};

export type GenerationParams = {
  maxTokens: CodegenTypes.Int32;
  temperature: CodegenTypes.Float;
  topK: CodegenTypes.Int32;
  topP: CodegenTypes.Float;
  seed: CodegenTypes.Int32;
  nThreads: CodegenTypes.Int32;
};

export type BackendDiagnostics = {
  requestedAccelerator: Accelerator;
  selectedAccelerator: 'cpu' | 'metal';
  contextSize: CodegenTypes.Int32;
  batchSize: CodegenTypes.Int32;
  modelLayers: CodegenTypes.Int32;
  offloadedLayers: CodegenTypes.Int32;
  kqvOffloaded: boolean;
  peakRssBytes: number;
};

export interface Spec extends TurboModule {
  loadModel(
    path: string,
    config: SessionConfig,
  ): Promise<CodegenTypes.Int32>;

  unloadModel(sessionId: CodegenTypes.Int32): Promise<void>;

  generate(
    sessionId: CodegenTypes.Int32,
    // React Native Codegen's schema parser requires this generic spelling.
    // eslint-disable-next-line @typescript-eslint/array-type
    messages: ReadonlyArray<NativeChatMessage>,
    params: GenerationParams,
  ): CodegenTypes.Int32;

  cancel(
    sessionId: CodegenTypes.Int32,
    requestId: CodegenTypes.Int32,
  ): void;

  getDiagnostics(
    sessionId: CodegenTypes.Int32,
  ): Promise<BackendDiagnostics>;

  // Required by NativeEventEmitter/RCTEventEmitter.
  addListener(eventName: string): void;
  removeListeners(count: CodegenTypes.Int32): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('PocketLM');
