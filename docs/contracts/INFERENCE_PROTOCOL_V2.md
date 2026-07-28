# Inference Protocol v2

Status: implemented cross-layer contract.

The normative C declaration is `cpp/include/pocketlm_core.h`. The normative
TurboModule declaration is `app/src/lib/NativePocketLM.ts`. This document fixes
cross-layer semantics that type declarations alone cannot express.

## Session lifecycle

Each successful `pocketlm_create_v2` owns one immutable llama model, one
inference context, one persistent worker, and at most one accepted request.

```text
Created/Idle -> Queued -> Prefilling -> Decoding -> Finishing -> Idle
      |           |           |            |
      +-----------+-----------+------------+-- destroy -> ShuttingDown -> Destroyed
```

A generation submitted outside Idle is rejected synchronously with
`POCKETLM_GENERATE_BUSY`. A generation submitted after shutdown starts is
rejected with `POCKETLM_GENERATE_SHUTTING_DOWN`. Rejected work never invokes
its callback. The complete synchronous result mapping is:

| Result | Meaning |
|---:|---|
| `-1` | invalid argument |
| `-2` | busy |
| `-3` | shutting down |
| `-4` | allocation failure while copying the request |
| `-5` | request-ID space exhausted |

Create requires a non-empty, valid UTF-8 `model_path` and a non-null
`out_session`. It stores null in `*out_session` before validation and leaves it
null on every failure. A null create config selects
`pocketlm_default_session_config()`. Generate requires a live session, a
non-null callback, at least one message, and a non-null message array. A null
generation-params pointer selects `pocketlm_default_params()`; `user_data` may
be null. `destroy(NULL)` and `cancel(NULL, ...)` are no-ops,
`peak_rss_bytes(NULL)` is zero, and diagnostics requires both pointers.

Message content is non-null, non-empty, valid UTF-8. Before acceptance, the
core validates roles and the conversation shape: an optional first system message,
alternating complete user/assistant turns, and a final user message. Invalid
shape or scalar parameter ranges reject synchronously with `-1`. Valid session
configuration requires `context_size > 0`, a declared accelerator value, and
`gpu_layers >= 0`. Valid generation parameters require `max_tokens > 0`,
finite `temperature >= 0`, `top_k >= 0`, finite `0 < top_p <= 1`, and
`n_threads >= 0`; every Int32 value must already be in range. Busy,
shutdown, request-copy allocation failure, and ID exhaustion reject with
`-2` through `-5` respectively and never call back. Work requiring model
execution—chat templating, tokenization, prompt budgeting, prefill, sampling,
or decode—happens after acceptance; its failure produces one asynchronous
ERROR terminal, including OOM after acceptance. Create failures are returned
synchronously as `pocketlm_error_code` values.

An accepted request receives a positive, session-scoped, monotonically
increasing ID beginning at 1. IDs may collide across sessions, so the owning
identity is always the `(session, request_id)` tuple. Its messages, strings,
and parameters are copied before acceptance and owned by the request. The
callback function pointer and `user_data` pointer value are retained, not
deep-copied; `user_data` remains borrowed from the caller. The caller must keep
the referenced context alive until the terminal callback returns. The callback
may begin as soon as the request is accepted, including before the caller has
processed the function's return value, so the bridge must use the ID supplied
to the callback and must never patch it into callback state afterward.

## Event invariant

For every accepted request:

- Every callback has the exact accepted request ID.
- Zero or more TOKEN callbacks precede exactly one DONE or ERROR callback.
- No callback follows the terminal callback.
- TOKEN indices begin at zero and increase contiguously.
- All callback payload memory is borrowed and valid only for that callback.
- The bridge copies payload data before returning.
- Internal exceptions become one ERROR terminal and never cross the C ABI.
- Every terminal path releases the request and returns the session to Idle,
  unless destruction is already advancing it to Destroyed.

DONE represents EOS, output limit, cancellation, or context exhaustion. Worker
failures use ERROR; DONE never carries an error reason.

The callback payload mapping is normative and never null:

| Event | Payload | Required contents |
|---|---|---|
| `POCKETLM_EVT_TOKEN` | `const pocketlm_token_event *` | non-null bytes, length greater than zero, valid UTF-8, contiguous zero-based index |
| `POCKETLM_EVT_DONE` | `const pocketlm_stats *` | valid finish reason and final statistics |
| `POCKETLM_EVT_ERROR` | `const pocketlm_error *` | valid error code plus a non-empty valid UTF-8 message and byte length |

All payloads and nested byte pointers are borrowed for the callback duration.
No callback uses an unknown event type. JavaScript maps C enum names to the
lower-case discriminants in `InferenceEvent` without inventing new reasons or
error codes.

The bridge mapping is exact:

- TOKEN becomes `{type:'token', sessionId, requestId, index,
  tokenCount:1, text}` before optional adjacent coalescing; coalescing sums
  `tokenCount`, concatenates text, and preserves the first index.
- DONE maps EOS, MAX_TOKENS, CANCELLED, and CONTEXT_EXHAUSTED to `eos`,
  `max_tokens`, `cancelled`, and `context_exhausted`. Stats map to
  `prefillMs`, `decodeMs`, `promptTokens`, `generatedTokens`, and
  `peakRssBytes`.
- ERROR removes the `POCKETLM_ERR_` prefix from the declared C enum name and
  emits the resulting uppercase `InferenceErrorCode` plus the length-delimited
  UTF-8 message.

The bridge rejects an invalid enum, null payload, non-finite/out-of-range
numeric field, invalid UTF-8, or structurally invalid token as a native
contract fault. It must not reinterpret malformed memory as a normal event;
it cancels/tears down that session while retaining JS ownership until terminal
or awaited unload.

## UTF-8 and token indexing

A C TOKEN is a complete, valid UTF-8 transport fragment. It may contain bytes
assembled from more than one sampled model token. Its `index` identifies the
transport fragment, not a model-token ordinal. Sampled model-token counts are
reported separately as `generated_tokens` in terminal statistics.

The core retains an incomplete UTF-8 suffix. Malformed complete sequences are
replaced with U+FFFD while preserving subsequent valid text. At any terminal,
an incomplete final sequence is discarded; raw incomplete bytes are never
emitted.

The native bridge may coalesce contiguous C fragments for delivery. A
JavaScript token event therefore carries:

```typescript
{
  type: 'token';
  sessionId: number;
  requestId: number;
  index: number;       // first C fragment index in this event
  tokenCount: number;  // number of contiguous C fragments represented, >= 1
  text: string;
}
```

JavaScript advances `expectedTokenIndex` by `tokenCount`. An index below the
expected value is a duplicate and is ignored. An index above it is a transport
gap: JavaScript reports a transport error, moves the request to `cancelling`,
sends cancel once, ignores subsequent tokens, and retains the ownership lock
until the matching native terminal or an awaited unload/reset. It must not
terminate native ownership locally or admit overlapping work. Coalescing never
splits a C fragment or crosses a session/request boundary.

## Cancellation and destruction

`pocketlm_cancel` compares the numeric ID with the queued or active request in
the supplied session. Unknown, stale, completed, or nonmatching IDs in that
session are no-ops. Because request IDs are session-scoped, an ID taken from a
different session has no independently detectable provenance: if its numeric
value equals the supplied session's active ID, it refers to that active request.
Callers must always preserve the session/request tuple. Cancellation wakes a
queued worker, is checked between prefill chunks and every decode iteration,
and ends with one DONE carrying `POCKETLM_FINISH_CANCELLED`.

The pinned llama.cpp abort callback is CPU-only. It may reduce CPU decode
latency but is not evidence of sub-decode Metal cancellation. The portable
guarantee is cancellation between bounded prefill chunks and decode calls.

`pocketlm_destroy` rejects new work, requests cancellation, wakes the worker,
joins it, and only then frees context and model state. It returns after all
callbacks have completed; no callback may occur afterward. Destroy must not be
called recursively from the session's own callback.

The C handle cannot protect a caller that begins a new API call after another
thread has freed it. Before calling destroy, the owner must fence access to the
session handle so no new generate, cancel, diagnostics, or metrics call can
begin. Calls already admitted before destruction are synchronized by the
session. The iOS lifecycle queue is the required owner-side fence.

## Context and conversation

The API accepts system, user, and assistant messages. A conversation may have
an optional first system message followed by complete user/assistant turns and
must end in a user message. The core uses the loaded model's GGUF chat template.
It reformats and prefills the retained conversation on each turn; KV-cache reuse
is not implemented.

The output allowance is reserved first. The system message is preserved, then
the oldest complete user/assistant turns are removed until the prompt fits. An
oversized newest turn is rejected clearly. Prefill is chunked to the actual
context batch size and terminal statistics include prompt and generated token
counts.

## Accelerator contract

Accelerator selection occurs only at session creation:

- CPU forces zero GPU layers.
- `gpu_layers == 0` applies the backend policy: all supported layers when Metal
  is selected and zero on CPU. A positive value caps requested offload;
  negative values are invalid.
- METAL fails with `POCKETLM_ERR_METAL_UNAVAILABLE` if Metal offload cannot be
  selected; it never silently falls back.
- AUTO attempts Metal and otherwise creates a CPU session with the fallback
  visible in diagnostics.
- `requested_accelerator` preserves AUTO/CPU/METAL; `selected_accelerator` is
  always CPU or METAL and never AUTO. The bridge maps `kqv_offloaded == 0` to
  false and `== 1` to true; other values are a contract fault.

`offloaded_layers` is `-1` unless the pinned backend can report or the
integration can corroborate the value honestly. A configured layer count alone
must not be presented as measured offload. The application must either report
defensible Metal/offload diagnostics or describe the runtime as CPU-only.

## Native delivery and reload

The sole EventEmitter channel is the exact string `onInferenceEvent`,
exported to JavaScript as `INFERENCE_EVENT_NAME`. The native bridge emits every
TOKEN, DONE, and ERROR mapping on that channel; the JavaScript coordinator
subscribes only to that exported constant. Renaming or adding a channel is a
coordinated contract change.

The bridge targets one coherently registered Objective-C++ `PocketLM`
TurboModule.
Lifecycle/control operations use one serial queue. C callback data is copied
immediately and passed to a separate serial event-delivery queue. That queue
coalesces contiguous fragments at approximately 16 ms or a small byte threshold,
flushes all pending fragments before a terminal, and never drops events for an
active subscriber.

Native `sessionId` values are positive, process-scoped Int32 values allocated
monotonically from 1 and never reused before process restart; 0 is invalid.
Exhaustion rejects `loadModel`. A successful load installs the C handle before
resolving its Promise. More than one session may exist, and the bridge attaches
the owning native session ID to every event.

Generate performs a short synchronous hop to the lifecycle queue. An unknown
session or invalid JS input returns `-1`; a session being unloaded returns
`-3`; otherwise C rejection values pass through unchanged. A negative result
never emits an event. Cancel for an unknown session/request is a no-op.
Diagnostics and unload reject their Promises with `session_not_found` for an
unknown or already removed session.

Promise rejections expose a stable uppercase `code`. C creation failures use
the matching `InferenceErrorCode`; native-only failures use
`SESSION_ID_EXHAUSTED`, `SESSION_NOT_FOUND`, or `INTERNAL`. Error messages add
context but are not used for control flow.

Unload marks the session unavailable to new generation, cancels any accepted
request, calls the join-before-free C destroy path, flushes the copied terminal
through the serial delivery queue, removes the session ID, and only then
resolves. Thus an active request receives its terminal before unload resolves,
and no event for that session can be produced afterward.

C callbacks may occur before `pocketlm_generate_v2` returns. They only enqueue
copied native events; they never invoke JavaScript reentrantly. The bridge bars
EventEmitter delivery until the native `generate()` method has returned, and
delivery runs on a later JavaScript turn. JavaScript stores the returned
session/request tuple in its synchronous ref immediately, before dispatch or
await, so the first event can be correlated safely.

Each module subscription has a monotonically increasing subscriber token.
Invalidation clears a handler only if its token is still current, so delayed
Fast Refresh teardown cannot disconnect a newer module instance. Events from an
old native session are still delivered with their original IDs and are rejected
by JavaScript correlation.

## JavaScript active request

```typescript
type ActiveRequest = {
  sessionId: number;
  requestId: number;
  assistantId: string;
  expectedTokenIndex: number;
  phase: 'starting' | 'generating' | 'cancelling';
};
```

A synchronous submission lock is set before any dispatch or `await`. A negative
native request result is immediate failure and never enters generating state.
Only matching session/request events can mutate output. Cancel changes the phase
to cancelling and waits for the matching native terminal. Gap and watchdog
failures may expose an error and send cancel once, but cannot clear the native
ownership guard or permit overlap. Retry is enabled only after a matching
terminal; Reset awaits unload before clearing ownership.

## Model storage boundary

JavaScript never derives a native model path from `process.env.HOME`. Verified
provisioning publishes the model under:

```text
Library/Application Support/PocketLM/Models/
  qwen2.5-0.5b-q4km/
    model.gguf
    manifest.json
```

The directory component comes from catalog `appDirectoryName`, not catalog
`id`; the installed filename comes from catalog `installedFilename`.

Tests use deterministic native fakes or an explicitly injected development
path; this does not weaken the production sandbox-storage contract.

## Default values

`pocketlm_default_session_config()` returns a 2,048-token context, AUTO
accelerator selection, and backend-policy GPU layers (`0`).
`pocketlm_default_params()` returns 256 output tokens, temperature 0.7, top-k
40, top-p 0.9, seed -1, and automatic thread selection (`n_threads == 0`).
