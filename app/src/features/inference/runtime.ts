import type { ChatAction, ChatState, ActiveRequest } from './types';
import {
  InferenceCoordinator,
  type CoordinatorControlState,
  type InferenceCoordinatorDependencies,
  type Submission,
} from './coordinator';

export type InferenceRuntimeBinding = {
  getState: () => ChatState;
  dispatch: (action: ChatAction) => void;
  resolveModelPath: () => string;
};

export interface SharedInferenceRuntimeDependencies {
  native: InferenceCoordinatorDependencies['native'];
  subscribe: InferenceCoordinatorDependencies['subscribe'];
  initialBinding: InferenceRuntimeBinding;
  makeId: InferenceCoordinatorDependencies['makeId'];
  reportError?: InferenceCoordinatorDependencies['reportError'];
  reportDiagnostic?: InferenceCoordinatorDependencies['reportDiagnostic'];
  watchdogMs?: number;
}

const IDLE_CONTROL: CoordinatorControlState = {
  activePhase: null,
  busy: false,
  resetting: false,
};

/**
 * Process-lifetime inference owner.
 *
 * React bindings may detach and reattach as routes or Fast Refresh instances
 * change, but this object keeps the exact native tuple, event subscription, and
 * watchdog alive until terminal/unload. Teardown removes only its own
 * token-indexed binding/control subscriber; either cleanup order selects the
 * newest remaining live binding.
 */
export class SharedInferenceRuntime {
  private binding: InferenceRuntimeBinding | null;
  private readonly coordinator: InferenceCoordinator;
  private control: CoordinatorControlState = IDLE_CONTROL;
  private nextBindingToken = 1;
  private currentBindingToken: number | null = null;
  private readonly bindings = new Map<number, InferenceRuntimeBinding>();
  private readonly controlSubscribers = new Map<
    number,
    (state: CoordinatorControlState) => void
  >();

  constructor(dependencies: SharedInferenceRuntimeDependencies) {
    this.binding = dependencies.initialBinding;
    this.coordinator = new InferenceCoordinator({
      native: dependencies.native,
      subscribe: dependencies.subscribe,
      getState: () => this.requireBinding().getState(),
      dispatch: (action) => this.requireBinding().dispatch(action),
      resolveModelPath: () => this.requireBinding().resolveModelPath(),
      makeId: dependencies.makeId,
      reportError: dependencies.reportError,
      reportDiagnostic: dependencies.reportDiagnostic,
      watchdogMs: dependencies.watchdogMs,
      onControlState: (state) => this.receiveControlState(state),
    });
    this.control = this.coordinator.controlState;
    // The bootstrap binding seeds the coordinator's existing session snapshot
    // but is not live until attach() assigns it a teardown token.
    this.binding = null;
  }

  attach(
    binding: InferenceRuntimeBinding,
    onControlState: (state: CoordinatorControlState) => void,
  ): () => void {
    const token = this.nextBindingToken;
    this.nextBindingToken += 1;
    this.bindings.set(token, binding);
    this.currentBindingToken = token;
    this.binding = binding;
    this.controlSubscribers.set(token, onControlState);

    this.coordinator.start();
    onControlState(this.control);

    return () => {
      this.bindings.delete(token);
      this.controlSubscribers.delete(token);
      if (this.currentBindingToken === token) {
        this.restoreNewestBindingOrRetainOwned(binding);
      }
      this.stopIfUnownedAndUnobserved();
    };
  }

  get controlState(): CoordinatorControlState {
    return this.control;
  }

  get active(): Readonly<ActiveRequest> | null {
    return this.coordinator.active;
  }

  get canRetry(): boolean {
    return this.binding !== null && this.coordinator.canRetry;
  }

  get canRegenerate(): boolean {
    return this.binding !== null && this.coordinator.canRegenerate;
  }

  submit(prompt: string): Submission {
    if (this.binding === null) {
      return { admitted: false, completion: Promise.resolve() };
    }
    this.coordinator.start();
    return this.coordinator.submit(prompt);
  }

  retry(): Submission {
    if (this.binding === null) {
      return { admitted: false, completion: Promise.resolve() };
    }
    this.coordinator.start();
    return this.coordinator.retry();
  }

  regenerate(): Submission {
    if (this.binding === null) {
      return { admitted: false, completion: Promise.resolve() };
    }
    this.coordinator.start();
    return this.coordinator.regenerate();
  }

  cancel(): void {
    if (this.binding === null) return;
    this.coordinator.start();
    this.coordinator.cancel();
  }

  reset(): Promise<void> {
    if (this.binding === null) return Promise.resolve();
    this.coordinator.start();
    return this.coordinator.reset();
  }

  /** Test/process-shutdown hook; React route cleanup must use attach()'s token. */
  dispose(): void {
    this.bindings.clear();
    this.controlSubscribers.clear();
    this.currentBindingToken = null;
    this.coordinator.stop();
    this.binding = null;
  }

  private receiveControlState(state: CoordinatorControlState): void {
    this.control = state;
    for (const subscriber of this.controlSubscribers.values()) subscriber(state);
    this.stopIfUnownedAndUnobserved();
  }

  private stopIfUnownedAndUnobserved(): void {
    if (this.bindings.size === 0 && !this.control.busy) {
      this.currentBindingToken = null;
      this.binding = null;
      this.coordinator.stop();
    }
  }

  private restoreNewestBindingOrRetainOwned(
    detachedBinding: InferenceRuntimeBinding,
  ): void {
    let newest: [number, InferenceRuntimeBinding] | null = null;
    for (const entry of this.bindings.entries()) newest = entry;

    if (newest !== null) {
      this.currentBindingToken = newest[0];
      this.binding = newest[1];
      return;
    }

    this.currentBindingToken = null;
    // While native work is still owned, its terminal/reset actions need the
    // last valid provider dispatch even when no React consumer is mounted.
    this.binding = this.control.busy ? detachedBinding : null;
  }

  private requireBinding(): InferenceRuntimeBinding {
    if (this.binding === null) {
      throw new Error('Inference runtime has no live React binding.');
    }
    return this.binding;
  }
}
