# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

class M4ArtifactFixture
  RC_COMMIT = "a" * 40
  MODEL_SHA256 = "b" * 64
  COLLECTOR_NONCE = "c" * 32
  WORKLOAD_V1 = "m4-workload-v1"
  WORKLOAD_V2 = "m4-workload-v2"
  SUITES = %w[reproducibility utf8 cancellation memory benchmark].freeze
  FIXED = {
    "temperature" => 0.2,
    "topK" => 20,
    "topP" => 0.8,
    "seed" => 424_242,
    "nThreads" => 4
  }.freeze

  PROFILE_PARAMS = lambda do |benchmark_max_tokens|
    {
      "reproducibility" => FIXED.merge("maxTokens" => 64).freeze,
      "utf8" => FIXED.merge("maxTokens" => 16).freeze,
      "cancellation" => FIXED.merge("maxTokens" => 256).freeze,
      "memory" => FIXED.merge("maxTokens" => 32).freeze,
      "benchmark" => FIXED.merge("maxTokens" => benchmark_max_tokens).freeze
    }.freeze
  end
  PARAMS_BY_WORKLOAD = {
    WORKLOAD_V1 => PROFILE_PARAMS.call(128),
    WORKLOAD_V2 => PROFILE_PARAMS.call(512)
  }.freeze
  ORDER = [[0, 1, 2, 3, 4], [2, 3, 4, 0, 1], [4, 0, 1, 2, 3]].freeze

  attr_reader :run_directory, :suite, :workload_version

  def initialize(
    root,
    cancellation_latencies: (10..29).to_a,
    workload_version: WORKLOAD_V1,
    suite: "all"
  )
    raise ArgumentError, "unsupported fixture workload version" unless PARAMS_BY_WORKLOAD.key?(workload_version)
    raise ArgumentError, "unsupported fixture suite" unless %w[all memory].include?(suite)

    @workload_version = workload_version
    @suite = suite
    @params = PARAMS_BY_WORKLOAD.fetch(workload_version)
    @completed_suites = suite == "all" ? SUITES : %w[memory]
    @run_id = "m4-#{suite}-#{workload_version.split('-').last}-fixture"
    @run_directory = File.join(root, @run_id)
    @cursor = 100_000
    @cancellation_latencies = cancellation_latencies
  end

  def write!
    FileUtils.mkdir_p(@run_directory)
    documents.each do |filename, value|
      File.write(File.join(@run_directory, filename), JSON.pretty_generate(value) + "\n")
    end
    @run_directory
  end

  private

  def documents
    started_at = "2026-07-19T12:00:00.000Z"
    completed_at = "2026-07-19T13:00:00.000Z"
    manifest = {
      "schemaVersion" => 1,
      "workloadVersion" => @workload_version,
      "runId" => @run_id,
      "collectorNonce" => COLLECTOR_NONCE,
      "status" => "complete",
      "selectedSuite" => @suite,
      "selectedSuites" => @completed_suites,
      "startedAt" => started_at,
      "completedAt" => completed_at,
      "completedSuites" => @completed_suites,
      "scope" => {
        "resultClass" => "iOS Simulator qualification",
        "physicalDeviceClaim" => false,
        "externalInstrumentsRequiredForPostUnloadRss" => true,
        "nativeSentryTested" => false
      },
      "app" => {
        "platform" => "ios",
        "platformVersion" => "17.5",
        "buildMode" => "release",
        "appVersion" => "0.1.0",
        "jsEngine" => "Hermes",
        "appCommit" => RC_COMMIT
      },
      "sourceBinding" => {
        "appCommit" => RC_COMMIT,
        "appCommitEmbedded" => true,
        "note" => "The RC commit was embedded in the release bundle."
      },
      "model" => {
        "id" => "fixture-model",
        "displayName" => "Fixture Model",
        "family" => "qwen2",
        "sourceRepository" => "Fixture/Model-GGUF",
        "sourceRevision" => "c" * 40,
        "sourceFilename" => "fixture-q4_k_m.gguf",
        "installedFilename" => "model.gguf",
        "byteSize" => 491_400_032,
        "sha256" => MODEL_SHA256,
        "quantization" => "Q4_K_M",
        "installedAt" => "2026-07-19T11:00:00.000Z"
      },
      "sessionConfig" => { "contextSize" => 2048, "accelerator" => "cpu", "gpuLayers" => 0 },
      "fixedParameters" => @params,
      "workloadCounts" => {
        "reproducibilityRuns" => 5,
        "utf8SourceCases" => 25,
        "utf8InstructionVariants" => 4,
        "utf8Generations" => 100,
        "cancellationTrials" => 20,
        "memoryPrimingCyclesExcluded" => 1,
        "memoryMeasuredCycles" => 10,
        "benchmarkWarmupsExcluded" => 1,
        "benchmarkPrompts" => 5,
        "benchmarkPasses" => 3,
        "benchmarkMeasuredRuns" => 15
      },
      "limitations" => ["Simulator evidence only."],
      "eventDiagnostics" => {
        "ignoredForeignEventCount" => 0,
        "invalidEventCount" => 0,
        "postTerminalEventCount" => 0
      }
    }

    common_documents = {
      "manifest.json" => manifest,
      "COMPLETE.json" => {
        "schemaVersion" => 1,
        "runId" => @run_id,
        "suite" => @suite,
        "collectorNonce" => COLLECTOR_NONCE,
        "completedAt" => completed_at,
        "completedSuites" => @completed_suites
      },
      "memory.json" => memory_document
    }
    return common_documents if @suite == "memory"

    common_documents.merge(
      "reproducibility.json" => reproducibility_document,
      "utf8.json" => utf8_document,
      "cancellation.json" => cancellation_document,
      "benchmark.json" => benchmark_document
    )
  end

  def reproducibility_document
    prompt = "Explain deterministic seeds."
    runs = 5.times.map do |index|
      {
        "run" => index + 1,
        "diagnostics" => diagnostics,
        "generation" => generation(
          session_id: index + 1,
          request_id: 1,
          prompt: prompt,
          params: @params.fetch("reproducibility"),
          output: "Seeded output."
        )
      }
    end
    {
      "schemaVersion" => 1,
      "workloadVersion" => @workload_version,
      "status" => "passed",
      "prompt" => prompt,
      "requiredRunCount" => 5,
      "completedRunCount" => 5,
      "params" => @params.fetch("reproducibility"),
      "freshSessionPerRun" => true,
      "exactOutputAndTerminalIdentity" => true,
      "runs" => runs
    }
  end

  def utf8_document
    cases = 100.times.map do |index|
      id = format("utf8-%02d-%02d", (index / 25) + 1, (index % 25) + 1)
      prompt = "Preserve #{id}: 🌍 你好 — مرحبا"
      {
        "ordinal" => index + 1,
        "id" => id,
        "category" => "emoji-cjk-rtl",
        "prompt" => prompt,
        "generation" => generation(
          session_id: 10,
          request_id: index + 1,
          prompt: prompt,
          params: @params.fetch("utf8"),
          output: "🌍 你好 مرحبا #{index + 1}"
        )
      }
    end
    {
      "schemaVersion" => 1,
      "workloadVersion" => @workload_version,
      "status" => "passed",
      "corpusConstruction" => "fixture",
      "requiredGenerationCount" => 100,
      "completedGenerationCount" => 100,
      "params" => @params.fetch("utf8"),
      "allOutputsValidUnicodeScalars" => true,
      "cases" => cases
    }
  end

  def cancellation_document
    trials = @cancellation_latencies.each_with_index.map do |latency, index|
      {
        "trial" => index + 1,
        "generation" => generation(
          session_id: 20,
          request_id: index + 1,
          prompt: "Generate a long list.",
          params: @params.fetch("cancellation"),
          output: "1.",
          reason: "cancelled",
          cancellation_latency: latency
        ),
        "underLimit" => true
      }
    end
    {
      "schemaVersion" => 1,
      "workloadVersion" => @workload_version,
      "status" => "passed",
      "timingBoundary" => "before cancel invocation through matching DONE delivery",
      "cancellationInitiation" => "after first matching token event was observed",
      "strictLimitMs" => 200,
      "requiredTrialCount" => 20,
      "completedTrialCount" => 20,
      "allTrialsStrictlyUnderLimit" => true,
      "sameSessionAcrossAllTrials" => true,
      "finalPostCancelRecoveryProbeExcludedFromLatencyTrials" => generation(
        session_id: 20,
        request_id: 21,
        prompt: "Reply OK.",
        params: @params.fetch("memory"),
        output: "OK"
      ),
      "params" => @params.fetch("cancellation"),
      "trials" => trials
    }
  end

  def memory_document
    settle_ms = 10_000
    cycles = 11.times.map do |index|
      base = allocate_base(20_000)
      session_id = 30 + index
      capture = generation(
        session_id: session_id,
        request_id: 1,
        prompt: "Explain unload.",
        params: @params.fetch("memory"),
        output: "Unload releases session resources.",
        base: base + 3
      )
      marker_offsets = [0, 1, 2, 109, 110, 111, 112, 112 + settle_ms]
      phases = %w[
        pre-load post-load post-load-diagnostics post-terminal
        post-terminal-diagnostics pre-unload post-unload post-unload-settle
      ]
      markers = phases.zip(marker_offsets).map do |phase, offset|
        { "phase" => phase }.merge(stamp(base + offset))
      end
      {
        "ordinal" => index + 1,
        "kind" => index.zero? ? "priming-excluded" : "measured",
        "measuredCycle" => index.zero? ? nil : index,
        "includedInMemorySeries" => !index.zero?,
        "sessionId" => session_id,
        "markers" => markers,
        "lifecycleDurationsMs" => { "load" => 1, "unload" => 1 },
        "afterLoadDiagnostics" => diagnostics,
        "postTerminalDiagnostics" => diagnostics,
        "generation" => capture,
        "rssMetricSemantics" => {
          "afterLoadDiagnosticsPeakRssBytes" => "native sampled peak",
          "generationPeakRssBytes" => "native sampled peak",
          "postTerminalDiagnosticsPeakRssBytes" => "native sampled peak",
          "postUnloadRssBytes" => nil,
          "postUnloadRssSource" => "external Instruments trace only"
        }
      }
    end
    {
      "schemaVersion" => 1,
      "workloadVersion" => @workload_version,
      "status" => "completed",
      "method" => "one excluded priming cycle and ten measured cycles",
      "requiredMeasuredCycles" => 10,
      "completedMeasuredCycles" => 10,
      "primingCycleCount" => 1,
      "lifecycleSettleMs" => settle_ms,
      "params" => @params.fetch("memory"),
      "memoryCeilingAssertedByApp" => false,
      "note" => "The Instruments trace owns post-unload RSS interpretation.",
      "cycles" => cycles
    }
  end

  def benchmark_document
    prompts = 5.times.map do |index|
      {
        "id" => "bench-#{index + 1}",
        "qualityDimension" => "dimension #{index + 1}",
        "prompt" => "Benchmark prompt #{index + 1}."
      }
    end
    warmup = generation(
      session_id: 50,
      request_id: 1,
      prompt: prompts.first.fetch("prompt"),
      params: @params.fetch("benchmark"),
      output: "Warmup output."
    )
    ordinal = 0
    raw_runs = ORDER.each_with_index.flat_map do |order, pass_index|
      order.each_with_index.map do |prompt_index, position|
        ordinal += 1
        prompt = prompts.fetch(prompt_index)
        capture = generation(
          session_id: 50,
          request_id: ordinal + 1,
          prompt: prompt.fetch("prompt"),
          params: @params.fetch("benchmark"),
          output: "Benchmark output #{ordinal}."
        )
        {
          "measuredOrdinal" => ordinal,
          "pass" => pass_index + 1,
          "position" => position + 1,
          "promptIndex" => prompt_index,
          "promptId" => prompt.fetch("id"),
          "qualityDimension" => prompt.fetch("qualityDimension"),
          "prompt" => prompt.fetch("prompt"),
          "generation" => capture,
          "derived" => benchmark_derivation(capture)
        }
      end
    end
    {
      "schemaVersion" => 1,
      "workloadVersion" => @workload_version,
      "status" => "completed",
      "executionOrder" => "pass-major preregistered rotations",
      "promptTable" => prompts,
      "zeroBasedPromptOrderByPass" => ORDER,
      "warmupExcludedFromMeasuredRuns" => true,
      "excludedWarmup" => warmup,
      "requiredMeasuredRunCount" => 15,
      "completedMeasuredRunCount" => 15,
      "params" => @params.fetch("benchmark"),
      "rawRuns" => raw_runs,
      "derivation" => "fixture derivation"
    }
  end

  def generation(session_id:, request_id:, prompt:, params:, output:, reason: "eos",
                 cancellation_latency: nil, base: nil)
    base ||= allocate_base
    generate_invoked = stamp(base)
    request_accepted = stamp(base + 1)
    first_token = stamp(base + 5)
    cancel_invoked = cancellation_latency.nil? ? nil : stamp(base + 6)
    terminal_ms = cancellation_latency.nil? ? base + 105 : base + 6 + cancellation_latency
    terminal_delivered = stamp(terminal_ms)
    generated_tokens = 2
    delivered_fragment_count = 1
    stats = {
      "prefillMs" => 20,
      "decodeMs" => 80,
      "promptTokens" => 8,
      "generatedTokens" => generated_tokens,
      "peakRssBytes" => 500_000_000
    }
    token = first_token.merge(
      "type" => "token",
      "sessionId" => session_id,
      "requestId" => request_id,
      "index" => 0,
      # Fragment metadata is not a model-token counter. Keep the values
      # intentionally different so validator tests preserve that boundary.
      "tokenCount" => delivered_fragment_count,
      "text" => output
    )
    done = terminal_delivered.merge(
      "type" => "done",
      "sessionId" => session_id,
      "requestId" => request_id,
      "reason" => reason,
      "stats" => stats
    )
    cancellation = if cancellation_latency.nil?
                     nil
                   else
                     {
                       "streamObserved" => first_token,
                       "cancelInvoked" => cancel_invoked,
                       "cancelReturned" => stamp(base + 7),
                       "terminalDelivered" => terminal_delivered,
                       "latencyMs" => cancellation_latency
                     }
                   end
    {
      "sessionId" => session_id,
      "requestId" => request_id,
      "messages" => [{ "role" => "user", "content" => prompt }],
      "params" => params,
      "generateInvoked" => generate_invoked,
      "requestAccepted" => request_accepted,
      "firstTokenDelivered" => first_token,
      "terminalDelivered" => terminal_delivered,
      "terminal" => done,
      "rawEvents" => [token, done],
      "output" => output,
      "outputUtf8Hex" => output.encode(Encoding::UTF_8).unpack1("H*"),
      "outputUtf8ByteCount" => output.bytesize,
      "outputUnicodeScalarCount" => output.each_codepoint.count,
      "unicodeScalarValid" => true,
      "tokenIndicesContiguous" => true,
      "terminalCount" => 1,
      "postTerminalEventCount" => 0,
      "cancellation" => cancellation
    }
  end

  def benchmark_derivation(capture)
    stats = capture.dig("terminal", "stats")
    generated = stats.fetch("generatedTokens")
    decode_ms = stats.fetch("decodeMs")
    native_ms = stats.fetch("prefillMs") + decode_ms
    e2e_ms = capture.dig("terminalDelivered", "monotonicMs") -
             capture.dig("requestAccepted", "monotonicMs")
    ttft_ms = capture.dig("firstTokenDelivered", "monotonicMs") -
              capture.dig("requestAccepted", "monotonicMs")
    {
      "decodeTokensPerSecond" => generated * 1000.0 / decode_ms,
      "nativeInferenceTokensPerSecond" => generated * 1000.0 / native_ms,
      "endToEndTokensPerSecond" => generated * 1000.0 / e2e_ms,
      "timeToFirstDeliveredFragmentMs" => ttft_ms
    }
  end

  def diagnostics
    {
      "requestedAccelerator" => "cpu",
      "selectedAccelerator" => "cpu",
      "contextSize" => 2048,
      "batchSize" => 128,
      "modelLayers" => 24,
      "offloadedLayers" => 0,
      "kqvOffloaded" => false,
      "peakRssBytes" => 500_000_000
    }
  end

  def allocate_base(span = 1_000)
    value = @cursor
    @cursor += span
    value
  end

  def stamp(monotonic_ms)
    {
      "wallClock" => (Time.utc(2026, 7, 19) + monotonic_ms / 1000.0).iso8601(3),
      "monotonicMs" => monotonic_ms
    }
  end
end
