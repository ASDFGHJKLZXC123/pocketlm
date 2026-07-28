/** React binding for the process-lifetime request-correlated runtime. */

import { useCallback, useLayoutEffect, useRef, useState } from 'react';
import { NativeEventEmitter } from 'react-native';
import PocketLM, { INFERENCE_EVENT_NAME } from '../../lib/native';
import { captureException } from '../../lib/sentry';
import { useAppDispatch, useAppState } from '../../state/AppContext';
import type { ChatState } from './types';
import type { CoordinatorControlState } from './coordinator';
import {
  SharedInferenceRuntime,
  type InferenceRuntimeBinding,
} from './runtime';

const RUNTIME_GLOBAL_KEY = '__pocketlmInferenceRuntimeV2__' as const;

type PocketLMGlobal = typeof globalThis & {
  [RUNTIME_GLOBAL_KEY]?: SharedInferenceRuntime;
};

function makeId(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}

function missingProvisionedModel(): never {
  throw new Error(
    'No verified app-sandbox model is installed. Seed a verified model ' +
      'before running model-backed chat.',
  );
}

function getSharedRuntime(
  initialBinding: InferenceRuntimeBinding,
  watchdogMs?: number,
): SharedInferenceRuntime {
  const processGlobal = globalThis as PocketLMGlobal;
  let runtime = processGlobal[RUNTIME_GLOBAL_KEY];
  if (runtime === undefined) {
    const emitter = new NativeEventEmitter(PocketLM);
    runtime = new SharedInferenceRuntime({
      native: PocketLM,
      subscribe: (listener) =>
        emitter.addListener(INFERENCE_EVENT_NAME, listener),
      initialBinding,
      makeId,
      reportError: captureException,
      watchdogMs,
    });
    processGlobal[RUNTIME_GLOBAL_KEY] = runtime;
  }
  return runtime;
}

export interface UseInferenceOptions {
  /** Deterministic test/development injection only. */
  modelPath?: string;
  watchdogMs?: number;
}

export interface UseInferenceReturn {
  /** Returns true only when this call acquired the synchronous submit lock. */
  submit: (prompt: string) => boolean;
  cancel: () => void;
  retry: () => boolean;
  regenerate: () => boolean;
  reset: () => Promise<void>;
  activePhase: CoordinatorControlState['activePhase'];
  isBusy: boolean;
  isResetting: boolean;
  canRetry: boolean;
  canRegenerate: boolean;
}

export function useInference(
  options: UseInferenceOptions = {},
): UseInferenceReturn {
  const state = useAppState();
  const dispatch = useAppDispatch();
  const stateRef = useRef<ChatState>(state);

  // Keep event/callback reads on the render that produced the UI. A passive
  // effect leaves a full event-loop turn where submit guards can see old state.
  stateRef.current = state;

  const initialBinding: InferenceRuntimeBinding = {
    getState: () => stateRef.current,
    dispatch,
    resolveModelPath: () =>
      options.modelPath === undefined
        ? missingProvisionedModel()
        : options.modelPath,
  };
  const [runtime] = useState(() =>
    getSharedRuntime(initialBinding, options.watchdogMs),
  );
  const [control, setControl] = useState<CoordinatorControlState>(
    runtime.controlState,
  );

  useLayoutEffect(() => {
    const binding: InferenceRuntimeBinding = {
      getState: () => stateRef.current,
      dispatch,
      resolveModelPath: () =>
        options.modelPath === undefined
          ? missingProvisionedModel()
          : options.modelPath,
    };
    return runtime.attach(binding, setControl);
  }, [dispatch, options.modelPath, runtime]);

  const submit = useCallback(
    (prompt: string) => runtime.submit(prompt).admitted,
    [runtime],
  );
  const cancel = useCallback(() => runtime.cancel(), [runtime]);
  const retry = useCallback(() => runtime.retry().admitted, [runtime]);
  const regenerate = useCallback(
    () => runtime.regenerate().admitted,
    [runtime],
  );
  const reset = useCallback(async () => runtime.reset(), [runtime]);

  return {
    submit,
    cancel,
    retry,
    regenerate,
    reset,
    activePhase: control.activePhase,
    isBusy: control.busy,
    isResetting: control.resetting,
    canRetry: !control.busy && runtime.canRetry,
    canRegenerate: !control.busy && runtime.canRegenerate,
  };
}
