# Validation and limitations

PocketLM separates integration correctness from model quality. A successful
local generation proves that the stack runs; it does not prove that the model
is accurate, safe, multilingual, memory-leak-free, or production-ready.

## Automated checks

The repository includes checks for:

- TypeScript type safety, ESLint, Jest, and a static Expo iOS export;
- model catalog parsing, SHA-256 verification, and atomic provisioning;
- C and C++ public-header compatibility;
- request acceptance, streaming order, cancellation, destruction, context
  handling, UTF-8 transport, and model-backed inference;
- Objective-C++ bridge lifecycle and event-delivery behavior;
- AddressSanitizer, coverage, and a separate ThreadSanitizer concurrency lane;
- Debug and Release native builds; and
- a fresh iOS Simulator build with locked CocoaPods dependencies.

The exact commands and their requirements are documented in
[TOOLCHAIN.md](TOOLCHAIN.md).

## Environment-specific observations

The following are historical observations recorded on 2026-07-20 from source
commit `0665d4b70717cf6382e3e22532ec730f0ec18428`. They came from one fixed
arm64 iPhone 15 Pro / iOS 17.5 Release Simulator configuration using the
catalog-pinned Qwen2.5 0.5B Instruct Q4_K_M model (SHA-256
`74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`).
They are not cross-device benchmarks.

| Area | Observation | Interpretation |
| --- | --- | --- |
| Reproducibility | 5/5 seeded fresh-session outputs were byte-identical | Repeatable in that fixed environment only |
| UTF-8 transport | 100/100 emoji, CJK, and RTL stress generations preserved valid encoding and event order | Transport integrity, not multilingual understanding |
| Cancellation | 20/20 native cancellation terminals arrived below 200 ms; maximum 1.223 ms | Native-call-to-listener timing, not touch-to-screen latency |
| Output quality | 6/15 outputs passed; code and rewrite prompts passed, summary, arithmetic/reasoning, and multilingual prompts did not | No broad model-quality claim |
| Memory | Numeric retained-memory limits passed across ten cycles, but a conservative leak check reported 16 attributed rows totaling 256 bytes | No leak-free claim |

Generated logs, Xcode result bundles, raw traces, host paths, and Simulator
identifiers are intentionally not stored in the public source tree. The current
qualification runner uses a newer workload revision and can produce new
versioned runs, but it cannot exactly regenerate this historical table.

## Model quality

The pinned model is intentionally small. The recorded five-prompt,
three-sample workload produced:

| Category | Passing samples | Result |
| --- | ---: | --- |
| Code | 3/3 | Passed |
| Rewrite | 3/3 | Passed |
| Summary | 0/3 | Failed |
| Arithmetic/reasoning | 0/3 | Failed |
| Multilingual | 0/3 | Failed |
| **Total** | **6/15** | **2/5 prompt categories passed** |

Generated code was scored as text and was not compiled as part of that output
quality workload. These results do not establish factual reliability, safety,
general coding correctness, reasoning ability, or multilingual fluency.

## Memory lifecycle

A successful native session owns one model, one inference context, one worker,
copied request data, and at most one accepted request. Unload rejects new work,
requests cancellation, joins the worker, frees context and model state, flushes
the copied terminal event, and then resolves.

The measured retained-memory deltas stayed well below the project thresholds,
but the conservative attributed-row condition failed. Responsible-library
attribution alone does not establish root cause, and the available measurements
do not justify describing PocketLM as leak-free.

## Unsupported claims

The current project does not claim:

- physical-device execution or Metal-offload performance;
- general latency, energy, or thermal behavior;
- broad output quality, factual reliability, or safety;
- leak-free or universally bounded memory behavior;
- Sentry ingestion, delivery, upload, or native symbolication;
- signing, TestFlight, App Store, or production readiness; or
- Android support.
