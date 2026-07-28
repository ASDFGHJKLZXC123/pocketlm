// src/lib/native.ts
// Re-exports the TurboModule spec and its default export.
// The codegen-facing file is NativePocketLM.ts (must start with "Native" per
// RN codegen filename convention — filterJSFile in combine-js-to-schema.js
// requires /^(Native.+|.+NativeComponent)/ on the basename).
export type {
  Accelerator,
  BackendDiagnostics,
  GenerationParams,
  NativeChatMessage,
  SessionConfig,
  Spec,
} from './NativePocketLM';
export { INFERENCE_EVENT_NAME } from './NativePocketLM';
export { default } from './NativePocketLM';
