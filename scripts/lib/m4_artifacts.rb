# frozen_string_literal: true

require "digest"
require "json"
require "time"

module PocketLMM4Artifacts
  class Error < StandardError; end

  class Validator
    DONE_REASONS = %w[eos max_tokens cancelled context_exhausted].freeze
    MAX_INT32 = 2_147_483_647
    STRICT_CANCELLATION_LIMIT_MS = 200

    FIXED_SAMPLING = {
      "temperature" => 0.2,
      "topK" => 20,
      "topP" => 0.8,
      "seed" => 424_242,
      "nThreads" => 4
    }.freeze

    PROFILE_PARAMS = lambda do |benchmark_max_tokens|
      {
        "reproducibility" => FIXED_SAMPLING.merge("maxTokens" => 64).freeze,
        "utf8" => FIXED_SAMPLING.merge("maxTokens" => 16).freeze,
        "cancellation" => FIXED_SAMPLING.merge("maxTokens" => 256).freeze,
        "memory" => FIXED_SAMPLING.merge("maxTokens" => 32).freeze,
        "benchmark" => FIXED_SAMPLING.merge("maxTokens" => benchmark_max_tokens).freeze
      }.freeze
    end
    WORKLOAD_PROFILES = {
      "m4-workload-v1" => PROFILE_PARAMS.call(128),
      "m4-workload-v2" => PROFILE_PARAMS.call(512)
    }.freeze

    ALL_SUITES = %w[reproducibility utf8 cancellation memory benchmark].freeze
    SUITE_PROFILES = {
      "all" => {
        files: %w[
          COMPLETE.json
          benchmark.json
          cancellation.json
          manifest.json
          memory.json
          reproducibility.json
          utf8.json
        ].freeze,
        completed_suites: ALL_SUITES
      }.freeze,
      "memory" => {
        files: %w[COMPLETE.json manifest.json memory.json].freeze,
        completed_suites: %w[memory].freeze
      }.freeze
    }.freeze
    BENCHMARK_ORDER = [
      [0, 1, 2, 3, 4],
      [2, 3, 4, 0, 1],
      [4, 0, 1, 2, 3]
    ].freeze

    SENSITIVE_KEYS = %w[
      password passwd secret clientsecret apikey accesskey accesstoken
      refreshtoken authtoken authorization cookie sessioncookie dsn sentrydsn
      privatekey credential credentials
    ].freeze
    PRIVATE_PATH_PATTERN = %r{
      (?:\A|[\s"'(=])
      (?:file://)?
      (?:
        /(?!/)[A-Za-z0-9._~+-]+(?:/|\z)|
        ~/(?:[^\s]*)|
        [A-Za-z]:\\[A-Za-z0-9._~+ -]+\\
      )
    }ix
    CREDENTIAL_VALUE_PATTERNS = [
      /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
      /\bsk-[A-Za-z0-9_-]{20,}\b/,
      /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
      /\bAKIA[0-9A-Z]{16}\b/,
      /\bBearer\s+[A-Za-z0-9._~+\/=:-]{12,}/i,
      /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
      %r{\Ahttps?://[^/\s@]+@}i,
      %r{\Ahttps?://[^/\s:@]+:[^/\s@]+@}i
    ].freeze

    def initialize(
      run_directory:,
      expected_rc:,
      expected_model_sha256:,
      expected_collector_nonce:,
      expected_workload_version:,
      expected_suite:
    )
      @run_directory = File.expand_path(run_directory)
      @expected_workload_version = supported_value!(
        expected_workload_version,
        WORKLOAD_PROFILES,
        "expected workload version"
      )
      @expected_suite = supported_value!(expected_suite, SUITE_PROFILES, "expected suite")
      @expected_params = WORKLOAD_PROFILES.fetch(@expected_workload_version)
      suite_profile = SUITE_PROFILES.fetch(@expected_suite)
      @expected_files = suite_profile.fetch(:files)
      @expected_suites = suite_profile.fetch(:completed_suites)
      @expected_rc = normalize_hex(expected_rc, 40, "expected RC commit")
      @expected_model_sha256 = normalize_hex(
        expected_model_sha256,
        64,
        "expected model SHA-256"
      )
      @expected_collector_nonce = normalize_hex(
        expected_collector_nonce,
        32,
        "expected collector nonce"
      )
      @documents = {}
    end

    def validate!
      load_documents!
      scan_for_private_material!
      manifest = validate_manifest!
      validate_complete!(manifest)
      suites = if @expected_suite == "all"
                 {
                   "reproducibility" => validate_reproducibility!,
                   "utf8" => validate_utf8!,
                   "cancellation" => validate_cancellation!,
                   "memory" => validate_memory!,
                   "benchmark" => validate_benchmark!
                 }
               else
                 { "memory" => validate_memory! }
               end

      build_summary(manifest, suites)
    end

    private

    def supported_value!(value, profiles, label)
      unless value.is_a?(String) && profiles.key?(value)
        raise Error, "#{label} must be one of: #{profiles.keys.join(', ')}"
      end

      value
    end

    def normalize_hex(value, length, label)
      unless value.is_a?(String) && value.match?(/\A[0-9a-f]{#{length}}\z/i)
        raise Error, "#{label} must be exactly #{length} hexadecimal characters"
      end

      value.downcase
    end

    def load_documents!
      begin
        stat = File.lstat(@run_directory)
      rescue Errno::ENOENT
        raise Error, "run directory does not exist"
      end
      fail_at("run directory", "must be a real directory, not a symlink") if stat.symlink?
      fail_at("run directory", "must be a directory") unless stat.directory?

      entries = Dir.children(@run_directory).sort
      missing = @expected_files - entries
      unexpected = entries - @expected_files
      fail_at("run directory", "is missing #{missing.join(', ')}") unless missing.empty?
      fail_at("run directory", "contains unexpected entries: #{unexpected.join(', ')}") unless unexpected.empty?

      @expected_files.each do |filename|
        path = File.join(@run_directory, filename)
        file_stat = File.lstat(path)
        fail_at(filename, "must be a regular non-symlink file") unless file_stat.file? && !file_stat.symlink?
        fail_at(filename, "is unreasonably large") if file_stat.size > 256 * 1024 * 1024

        raw = File.binread(path)
        raw.force_encoding(Encoding::UTF_8)
        fail_at(filename, "is not valid UTF-8") unless raw.valid_encoding?
        begin
          document = JSON.parse(raw)
        rescue JSON::ParserError => error
          fail_at(filename, "is not valid JSON (#{error.message})")
        end
        @documents[filename] = object!(document, filename)
      end
    rescue Errno::EACCES, Errno::EIO => error
      raise Error, "cannot read run directory: #{error.message}"
    end

    def scan_for_private_material!
      @documents.each do |filename, document|
        scan_value!(document, filename)
      end
    end

    def scan_value!(value, path)
      case value
      when Hash
        value.each do |key, child|
          normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
          if SENSITIVE_KEYS.include?(normalized)
            fail_at("#{path}.#{key}", "uses a credential-like field name")
          end
          scan_value!(child, "#{path}.#{key}")
        end
      when Array
        value.each_with_index { |child, index| scan_value!(child, "#{path}[#{index}]") }
      when String
        fail_at(path, "contains a private absolute path") if value.match?(PRIVATE_PATH_PATTERN)
        if CREDENTIAL_VALUE_PATTERNS.any? { |pattern| value.match?(pattern) }
          fail_at(path, "contains a credential-like value")
        end
      end
    end

    def validate_manifest!
      manifest = @documents.fetch("manifest.json")
      equal_at!(manifest["schemaVersion"], 1, "manifest.json.schemaVersion")
      equal_at!(
        manifest["workloadVersion"],
        @expected_workload_version,
        "manifest.json.workloadVersion"
      )
      equal_at!(manifest["status"], "complete", "manifest.json.status")
      equal_at!(manifest["selectedSuite"], @expected_suite, "manifest.json.selectedSuite")
      equal_at!(manifest["selectedSuites"], @expected_suites, "manifest.json.selectedSuites")
      equal_at!(manifest["completedSuites"], @expected_suites, "manifest.json.completedSuites")
      run_id = safe_run_id!(manifest["runId"], "manifest.json.runId")
      equal_at!(
        manifest["collectorNonce"],
        @expected_collector_nonce,
        "manifest.json.collectorNonce"
      )
      iso_time!(manifest["startedAt"], "manifest.json.startedAt")
      iso_time!(manifest["completedAt"], "manifest.json.completedAt")

      scope = object!(manifest["scope"], "manifest.json.scope")
      equal_at!(scope["resultClass"], "iOS Simulator qualification", "manifest.json.scope.resultClass")
      equal_at!(scope["physicalDeviceClaim"], false, "manifest.json.scope.physicalDeviceClaim")
      equal_at!(
        scope["externalInstrumentsRequiredForPostUnloadRss"],
        true,
        "manifest.json.scope.externalInstrumentsRequiredForPostUnloadRss"
      )
      equal_at!(scope["nativeSentryTested"], false, "manifest.json.scope.nativeSentryTested")

      app = object!(manifest["app"], "manifest.json.app")
      equal_at!(app["platform"], "ios", "manifest.json.app.platform")
      nonempty_string!(app["platformVersion"], "manifest.json.app.platformVersion")
      equal_at!(app["buildMode"], "release", "manifest.json.app.buildMode")
      equal_at!(app["appCommit"], @expected_rc, "manifest.json.app.appCommit")

      binding = object!(manifest["sourceBinding"], "manifest.json.sourceBinding")
      equal_at!(binding["appCommit"], @expected_rc, "manifest.json.sourceBinding.appCommit")
      equal_at!(binding["appCommitEmbedded"], true, "manifest.json.sourceBinding.appCommitEmbedded")

      model = object!(manifest["model"], "manifest.json.model")
      equal_at!(model["sha256"], @expected_model_sha256, "manifest.json.model.sha256")
      source_filename = basename_string!(model["sourceFilename"], "manifest.json.model.sourceFilename")
      installed_filename = basename_string!(
        model["installedFilename"],
        "manifest.json.model.installedFilename"
      )
      fail_at("manifest.json.model", "source and installed filenames must be recorded") if source_filename.empty? || installed_filename.empty?

      session = object!(manifest["sessionConfig"], "manifest.json.sessionConfig")
      equal_at!(session["accelerator"], "cpu", "manifest.json.sessionConfig.accelerator")
      equal_at!(session["gpuLayers"], 0, "manifest.json.sessionConfig.gpuLayers")
      positive_integer!(session["contextSize"], "manifest.json.sessionConfig.contextSize")

      fixed = object!(manifest["fixedParameters"], "manifest.json.fixedParameters")
      @expected_params.each do |suite, params|
        equal_at!(fixed[suite], params, "manifest.json.fixedParameters.#{suite}")
      end

      counts = object!(manifest["workloadCounts"], "manifest.json.workloadCounts")
      expected_counts = {
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
      }
      expected_counts.each do |key, value|
        equal_at!(counts[key], value, "manifest.json.workloadCounts.#{key}")
      end

      diagnostics = object!(manifest["eventDiagnostics"], "manifest.json.eventDiagnostics")
      %w[ignoredForeignEventCount invalidEventCount postTerminalEventCount].each do |key|
        equal_at!(diagnostics[key], 0, "manifest.json.eventDiagnostics.#{key}")
      end

      {
        "runId" => run_id,
        "app" => app,
        "scope" => scope,
        "model" => model,
        "sessionConfig" => session
      }
    end

    def validate_complete!(manifest)
      complete = @documents.fetch("COMPLETE.json")
      equal_at!(complete["schemaVersion"], 1, "COMPLETE.json.schemaVersion")
      equal_at!(complete["runId"], manifest.fetch("runId"), "COMPLETE.json.runId")
      equal_at!(complete["suite"], @expected_suite, "COMPLETE.json.suite")
      equal_at!(
        complete["collectorNonce"],
        @expected_collector_nonce,
        "COMPLETE.json.collectorNonce"
      )
      equal_at!(
        complete["completedSuites"],
        @expected_suites,
        "COMPLETE.json.completedSuites"
      )
      iso_time!(complete["completedAt"], "COMPLETE.json.completedAt")
      equal_at!(complete["completedAt"], @documents.fetch("manifest.json")["completedAt"], "COMPLETE.json.completedAt")
    end

    def validate_reproducibility!
      document = suite_document!("reproducibility", "passed")
      equal_at!(document["requiredRunCount"], 5, "reproducibility.json.requiredRunCount")
      equal_at!(document["completedRunCount"], 5, "reproducibility.json.completedRunCount")
      equal_at!(document["freshSessionPerRun"], true, "reproducibility.json.freshSessionPerRun")
      equal_at!(
        document["exactOutputAndTerminalIdentity"],
        true,
        "reproducibility.json.exactOutputAndTerminalIdentity"
      )
      equal_at!(
        document["params"],
        @expected_params.fetch("reproducibility"),
        "reproducibility.json.params"
      )
      prompt = nonempty_string!(document["prompt"], "reproducibility.json.prompt")
      runs = exact_array_length!(document["runs"], 5, "reproducibility.json.runs")
      captures = runs.each_with_index.map do |run_value, index|
        run = object!(run_value, "reproducibility.json.runs[#{index}]")
        equal_at!(run["run"], index + 1, "reproducibility.json.runs[#{index}].run")
        validate_diagnostics!(run["diagnostics"], "reproducibility.json.runs[#{index}].diagnostics")
        validate_generation!(
          run["generation"],
          "reproducibility.json.runs[#{index}].generation",
          expected_params: @expected_params.fetch("reproducibility"),
          expected_prompt: prompt,
          cancelled: false
        )
      end
      unique_at!(captures.map { |capture| capture.fetch("sessionId") }, "reproducibility fresh session IDs")
      first = captures.first
      captures.drop(1).each_with_index do |capture, index|
        %w[output outputUtf8Hex].each do |field|
          equal_at!(capture[field], first[field], "reproducibility run #{index + 2} #{field}")
        end
        equal_at!(capture.dig("terminal", "reason"), first.dig("terminal", "reason"), "reproducibility run #{index + 2} terminal reason")
        equal_at!(
          capture.dig("terminal", "stats", "generatedTokens"),
          first.dig("terminal", "stats", "generatedTokens"),
          "reproducibility run #{index + 2} generatedTokens"
        )
      end

      {
        "runCount" => captures.length,
        "exactOutputAndTerminalIdentity" => true,
        "outputUtf8Sha256" => Digest::SHA256.hexdigest(first.fetch("output").encode(Encoding::UTF_8)),
        "outputUtf8ByteCount" => first.fetch("outputUtf8ByteCount"),
        "terminalReason" => first.dig("terminal", "reason"),
        "generatedTokens" => first.dig("terminal", "stats", "generatedTokens")
      }
    end

    def validate_utf8!
      document = suite_document!("utf8", "passed")
      equal_at!(document["requiredGenerationCount"], 100, "utf8.json.requiredGenerationCount")
      equal_at!(document["completedGenerationCount"], 100, "utf8.json.completedGenerationCount")
      equal_at!(document["allOutputsValidUnicodeScalars"], true, "utf8.json.allOutputsValidUnicodeScalars")
      equal_at!(document["params"], @expected_params.fetch("utf8"), "utf8.json.params")
      cases = exact_array_length!(document["cases"], 100, "utf8.json.cases")
      ids = []
      prompts = []
      captures = cases.each_with_index.map do |case_value, index|
        entry = object!(case_value, "utf8.json.cases[#{index}]")
        equal_at!(entry["ordinal"], index + 1, "utf8.json.cases[#{index}].ordinal")
        expected_id = format("utf8-%02d-%02d", (index / 25) + 1, (index % 25) + 1)
        equal_at!(entry["id"], expected_id, "utf8.json.cases[#{index}].id")
        equal_at!(entry["category"], "emoji-cjk-rtl", "utf8.json.cases[#{index}].category")
        prompt = nonempty_string!(entry["prompt"], "utf8.json.cases[#{index}].prompt")
        ids << entry["id"]
        prompts << prompt
        validate_generation!(
          entry["generation"],
          "utf8.json.cases[#{index}].generation",
          expected_params: @expected_params.fetch("utf8"),
          expected_prompt: prompt,
          cancelled: false
        )
      end
      unique_at!(ids, "UTF-8 case IDs")
      unique_at!(prompts, "UTF-8 prompts")
      unique_at!(captures.map { |capture| capture.fetch("sessionId") }, "UTF-8 session IDs", expected_count: 1)
      unique_at!(captures.map { |capture| capture.fetch("requestId") }, "UTF-8 request IDs")

      {
        "generationCount" => captures.length,
        "validUnicodeScalarOutputCount" => captures.count { |capture| capture["unicodeScalarValid"] },
        "totalOutputUtf8Bytes" => captures.sum { |capture| capture.fetch("outputUtf8ByteCount") },
        "totalOutputUnicodeScalars" => captures.sum { |capture| capture.fetch("outputUnicodeScalarCount") },
        "totalGeneratedTokens" => captures.sum { |capture| capture.dig("terminal", "stats", "generatedTokens") }
      }
    end

    def validate_cancellation!
      document = suite_document!("cancellation", "passed")
      equal_at!(document["strictLimitMs"], STRICT_CANCELLATION_LIMIT_MS, "cancellation.json.strictLimitMs")
      equal_at!(document["requiredTrialCount"], 20, "cancellation.json.requiredTrialCount")
      equal_at!(document["completedTrialCount"], 20, "cancellation.json.completedTrialCount")
      equal_at!(document["allTrialsStrictlyUnderLimit"], true, "cancellation.json.allTrialsStrictlyUnderLimit")
      equal_at!(document["sameSessionAcrossAllTrials"], true, "cancellation.json.sameSessionAcrossAllTrials")
      equal_at!(
        document["params"],
        @expected_params.fetch("cancellation"),
        "cancellation.json.params"
      )
      nonempty_string!(document["timingBoundary"], "cancellation.json.timingBoundary")
      nonempty_string!(document["cancellationInitiation"], "cancellation.json.cancellationInitiation")

      trials = exact_array_length!(document["trials"], 20, "cancellation.json.trials")
      captures = trials.each_with_index.map do |trial_value, index|
        trial = object!(trial_value, "cancellation.json.trials[#{index}]")
        equal_at!(trial["trial"], index + 1, "cancellation.json.trials[#{index}].trial")
        equal_at!(trial["underLimit"], true, "cancellation.json.trials[#{index}].underLimit")
        validate_generation!(
          trial["generation"],
          "cancellation.json.trials[#{index}].generation",
          expected_params: @expected_params.fetch("cancellation"),
          cancelled: true
        )
      end
      unique_at!(captures.map { |capture| capture.fetch("sessionId") }, "cancellation session IDs", expected_count: 1)
      unique_at!(captures.map { |capture| capture.fetch("requestId") }, "cancellation request IDs")
      unique_at!(
        captures.map { |capture| capture.dig("messages", 0, "content") },
        "cancellation prompts",
        expected_count: 1
      )

      recovery = validate_generation!(
        document["finalPostCancelRecoveryProbeExcludedFromLatencyTrials"],
        "cancellation.json.finalPostCancelRecoveryProbeExcludedFromLatencyTrials",
        expected_params: @expected_params.fetch("memory"),
        cancelled: false
      )
      equal_at!(recovery["sessionId"], captures.first.fetch("sessionId"), "cancellation recovery sessionId")
      if captures.any? { |capture| capture.fetch("requestId") == recovery.fetch("requestId") }
        fail_at("cancellation recovery requestId", "must be distinct from latency trials")
      end
      latencies = captures.map { |capture| capture.dig("cancellation", "latencyMs") }

      {
        "trialCount" => captures.length,
        "allMatchingTerminalsCancelled" => true,
        "streamObservedBeforeEveryCancel" => true,
        "strictLimitMs" => STRICT_CANCELLATION_LIMIT_MS,
        "latencyMs" => describe(latencies),
        "percentileMethod" => "nearest-rank",
        "recoveryProbePassed" => true
      }
    end

    def validate_memory!
      document = suite_document!("memory", "completed")
      equal_at!(document["requiredMeasuredCycles"], 10, "memory.json.requiredMeasuredCycles")
      equal_at!(document["completedMeasuredCycles"], 10, "memory.json.completedMeasuredCycles")
      equal_at!(document["primingCycleCount"], 1, "memory.json.primingCycleCount")
      settle_ms = nonnegative_number!(document["lifecycleSettleMs"], "memory.json.lifecycleSettleMs")
      fail_at("memory.json.lifecycleSettleMs", "must be positive") unless settle_ms.positive?
      equal_at!(document["params"], @expected_params.fetch("memory"), "memory.json.params")
      equal_at!(document["memoryCeilingAssertedByApp"], false, "memory.json.memoryCeilingAssertedByApp")
      note = nonempty_string!(document["note"], "memory.json.note")
      fail_at("memory.json.note", "must assign post-unload interpretation to Instruments") unless note.match?(/Instruments/i)

      cycles = exact_array_length!(document["cycles"], 11, "memory.json.cycles")
      session_ids = []
      cycles.each_with_index do |cycle_value, index|
        path = "memory.json.cycles[#{index}]"
        cycle = object!(cycle_value, path)
        equal_at!(cycle["ordinal"], index + 1, "#{path}.ordinal")
        if index.zero?
          equal_at!(cycle["kind"], "priming-excluded", "#{path}.kind")
          equal_at!(cycle["measuredCycle"], nil, "#{path}.measuredCycle")
          equal_at!(cycle["includedInMemorySeries"], false, "#{path}.includedInMemorySeries")
        else
          equal_at!(cycle["kind"], "measured", "#{path}.kind")
          equal_at!(cycle["measuredCycle"], index, "#{path}.measuredCycle")
          equal_at!(cycle["includedInMemorySeries"], true, "#{path}.includedInMemorySeries")
        end
        session_id = positive_int32!(cycle["sessionId"], "#{path}.sessionId")
        session_ids << session_id
        validate_diagnostics!(cycle["afterLoadDiagnostics"], "#{path}.afterLoadDiagnostics")
        validate_diagnostics!(cycle["postTerminalDiagnostics"], "#{path}.postTerminalDiagnostics")
        capture = validate_generation!(
          cycle["generation"],
          "#{path}.generation",
          expected_params: @expected_params.fetch("memory"),
          cancelled: false
        )
        equal_at!(capture["sessionId"], session_id, "#{path}.generation.sessionId")
        validate_memory_markers!(cycle, path, settle_ms)
        semantics = object!(cycle["rssMetricSemantics"], "#{path}.rssMetricSemantics")
        equal_at!(semantics["postUnloadRssBytes"], nil, "#{path}.rssMetricSemantics.postUnloadRssBytes")
        equal_at!(
          semantics["postUnloadRssSource"],
          "external Instruments trace only",
          "#{path}.rssMetricSemantics.postUnloadRssSource"
        )
      end
      unique_at!(session_ids, "memory lifecycle session IDs")
      unique_at!(
        cycles.map { |cycle| cycle.dig("generation", "messages", 0, "content") },
        "memory lifecycle prompts",
        expected_count: 1
      )

      {
        "primingCyclesExcluded" => 1,
        "measuredCycles" => 10,
        "lifecycleSettleMs" => settle_ms,
        "appMemoryCeilingClaimed" => false,
        "postUnloadRssEvidenceRequired" => "external Instruments trace"
      }
    end

    def validate_benchmark!
      document = suite_document!("benchmark", "completed")
      equal_at!(document["executionOrder"], "pass-major preregistered rotations", "benchmark.json.executionOrder")
      equal_at!(document["zeroBasedPromptOrderByPass"], BENCHMARK_ORDER, "benchmark.json.zeroBasedPromptOrderByPass")
      equal_at!(document["warmupExcludedFromMeasuredRuns"], true, "benchmark.json.warmupExcludedFromMeasuredRuns")
      equal_at!(document["requiredMeasuredRunCount"], 15, "benchmark.json.requiredMeasuredRunCount")
      equal_at!(document["completedMeasuredRunCount"], 15, "benchmark.json.completedMeasuredRunCount")
      equal_at!(
        document["params"],
        @expected_params.fetch("benchmark"),
        "benchmark.json.params"
      )

      prompts = exact_array_length!(document["promptTable"], 5, "benchmark.json.promptTable").each_with_index.map do |value, index|
        prompt = object!(value, "benchmark.json.promptTable[#{index}]")
        {
          "id" => nonempty_string!(prompt["id"], "benchmark.json.promptTable[#{index}].id"),
          "qualityDimension" => nonempty_string!(prompt["qualityDimension"], "benchmark.json.promptTable[#{index}].qualityDimension"),
          "prompt" => nonempty_string!(prompt["prompt"], "benchmark.json.promptTable[#{index}].prompt")
        }
      end
      unique_at!(prompts.map { |prompt| prompt.fetch("id") }, "benchmark prompt IDs")
      unique_at!(prompts.map { |prompt| prompt.fetch("prompt") }, "benchmark prompt text")

      warmup = validate_generation!(
        document["excludedWarmup"],
        "benchmark.json.excludedWarmup",
        expected_params: @expected_params.fetch("benchmark"),
        expected_prompt: prompts.first.fetch("prompt"),
        cancelled: false
      )
      runs = exact_array_length!(document["rawRuns"], 15, "benchmark.json.rawRuns")
      records = []
      measured_ordinal = 0
      BENCHMARK_ORDER.each_with_index do |order, pass_index|
        order.each_with_index do |prompt_index, position|
          run = object!(runs.fetch(measured_ordinal), "benchmark.json.rawRuns[#{measured_ordinal}]")
          path = "benchmark.json.rawRuns[#{measured_ordinal}]"
          prompt = prompts.fetch(prompt_index)
          equal_at!(run["measuredOrdinal"], measured_ordinal + 1, "#{path}.measuredOrdinal")
          equal_at!(run["pass"], pass_index + 1, "#{path}.pass")
          equal_at!(run["position"], position + 1, "#{path}.position")
          equal_at!(run["promptIndex"], prompt_index, "#{path}.promptIndex")
          equal_at!(run["promptId"], prompt.fetch("id"), "#{path}.promptId")
          equal_at!(run["qualityDimension"], prompt.fetch("qualityDimension"), "#{path}.qualityDimension")
          equal_at!(run["prompt"], prompt.fetch("prompt"), "#{path}.prompt")
          capture = validate_generation!(
            run["generation"],
            "#{path}.generation",
            expected_params: @expected_params.fetch("benchmark"),
            expected_prompt: prompt.fetch("prompt"),
            cancelled: false
          )
          equal_at!(capture["sessionId"], warmup.fetch("sessionId"), "#{path}.generation.sessionId")
          derived = validate_benchmark_derivation!(run["derived"], capture, "#{path}.derived")
          records << {
            "promptId" => prompt.fetch("id"),
            "derived" => derived
          }
          measured_ordinal += 1
        end
      end

      throughput_fields = %w[
        decodeTokensPerSecond
        nativeInferenceTokensPerSecond
        endToEndTokensPerSecond
      ]
      unique_at!(
        [warmup, *runs.map { |run| run.fetch("generation") }].map { |capture| capture.fetch("requestId") },
        "benchmark request IDs"
      )
      throughput = throughput_fields.to_h do |field|
        values = records.map { |record| record.fetch("derived")[field] }.compact
        per_prompt = prompts.to_h do |prompt|
          prompt_values = records.filter_map do |record|
            record.fetch("promptId") == prompt.fetch("id") ? record.fetch("derived")[field] : nil
          end
          [prompt.fetch("id"), describe(prompt_values)]
        end
        [field, { "aggregate" => describe(values), "perPrompt" => per_prompt }]
      end

      {
        "promptCount" => prompts.length,
        "passesPerPrompt" => 3,
        "measuredRunCount" => records.length,
        "warmupExcluded" => true,
        "throughputUnit" => "tokens/second",
        "throughput" => throughput,
        "percentileMethod" => "nearest-rank"
      }
    end

    def suite_document!(name, status)
      filename = "#{name}.json"
      document = @documents.fetch(filename)
      equal_at!(document["schemaVersion"], 1, "#{filename}.schemaVersion")
      equal_at!(
        document["workloadVersion"],
        @expected_workload_version,
        "#{filename}.workloadVersion"
      )
      equal_at!(document["status"], status, "#{filename}.status")
      document
    end

    def validate_generation!(value, path, expected_params:, cancelled:, expected_prompt: nil)
      capture = object!(value, path)
      session_id = positive_int32!(capture["sessionId"], "#{path}.sessionId")
      request_id = positive_int32!(capture["requestId"], "#{path}.requestId")
      messages = exact_array_length!(capture["messages"], 1, "#{path}.messages")
      message = object!(messages.first, "#{path}.messages[0]")
      equal_at!(message["role"], "user", "#{path}.messages[0].role")
      prompt = nonempty_string!(message["content"], "#{path}.messages[0].content")
      equal_at!(prompt, expected_prompt, "#{path}.messages[0].content") unless expected_prompt.nil?
      equal_at!(capture["params"], expected_params, "#{path}.params")

      generate_invoked = timestamp!(capture["generateInvoked"], "#{path}.generateInvoked")
      request_accepted = timestamp!(capture["requestAccepted"], "#{path}.requestAccepted")
      terminal_delivered = timestamp!(capture["terminalDelivered"], "#{path}.terminalDelivered")
      ordered_at!(generate_invoked, request_accepted, "#{path} generate invocation/acceptance")
      ordered_at!(request_accepted, terminal_delivered, "#{path} acceptance/terminal")

      raw_events = array!(capture["rawEvents"], "#{path}.rawEvents")
      fail_at("#{path}.rawEvents", "must contain token events and one DONE") if raw_events.length < 2
      expected_index = 0
      output_parts = []
      tokens = []
      done_events = []
      previous = request_accepted
      raw_events.each_with_index do |event_value, index|
        event_path = "#{path}.rawEvents[#{index}]"
        event = object!(event_value, event_path)
        event_time = timestamp!(event, event_path)
        ordered_at!(previous, event_time, "#{event_path} delivery order")
        previous = event_time
        equal_at!(event["sessionId"], session_id, "#{event_path}.sessionId")
        equal_at!(event["requestId"], request_id, "#{event_path}.requestId")
        case event["type"]
        when "token"
          fail_at(event_path, "token arrived after DONE") unless done_events.empty?
          equal_at!(event["index"], expected_index, "#{event_path}.index")
          token_count = positive_int32!(event["tokenCount"], "#{event_path}.tokenCount")
          text = nonempty_string!(event["text"], "#{event_path}.text")
          fail_at("#{event_path}.text", "is not valid UTF-8") unless text.valid_encoding?
          expected_index += token_count
          output_parts << text
          tokens << event
        when "done"
          done_events << event
          fail_at(event_path, "DONE must be the final raw event") unless index == raw_events.length - 1
          fail_at("#{event_path}.reason", "is invalid") unless DONE_REASONS.include?(event["reason"])
          validate_stats!(event["stats"], "#{event_path}.stats")
        else
          fail_at("#{event_path}.type", "must be token or done in a successful capture")
        end
      end
      fail_at("#{path}.rawEvents", "must contain at least one token event") if tokens.empty?
      fail_at("#{path}.rawEvents", "must contain exactly one DONE") unless done_events.length == 1
      done = done_events.first
      # Raw token-event index/tokenCount describe contiguous C callback
      # fragments. They are deliberately not equated to model-token counts:
      # UTF-8 buffering can combine model tokens into a different number of
      # delivered fragments.
      generated_tokens = done.dig("stats", "generatedTokens")
      fail_at("#{path}.terminal.stats.generatedTokens", "must be positive") unless generated_tokens.positive?

      output = nonempty_string!(capture["output"], "#{path}.output")
      equal_at!(output, output_parts.join, "#{path}.output reconstructed from token events")
      fail_at("#{path}.output", "is not valid UTF-8") unless output.valid_encoding?
      expected_hex = output.encode(Encoding::UTF_8).unpack1("H*")
      equal_at!(capture["outputUtf8Hex"], expected_hex, "#{path}.outputUtf8Hex")
      equal_at!(capture["outputUtf8ByteCount"], output.bytesize, "#{path}.outputUtf8ByteCount")
      equal_at!(capture["outputUnicodeScalarCount"], output.each_codepoint.count, "#{path}.outputUnicodeScalarCount")
      equal_at!(capture["unicodeScalarValid"], true, "#{path}.unicodeScalarValid")
      equal_at!(capture["tokenIndicesContiguous"], true, "#{path}.tokenIndicesContiguous")
      equal_at!(capture["terminalCount"], 1, "#{path}.terminalCount")
      equal_at!(capture["postTerminalEventCount"], 0, "#{path}.postTerminalEventCount")
      equal_at!(capture["terminal"], done, "#{path}.terminal")
      equal_at!(capture["terminalDelivered"], timestamp_hash(done), "#{path}.terminalDelivered")

      first_token_time = timestamp!(capture["firstTokenDelivered"], "#{path}.firstTokenDelivered")
      equal_at!(capture["firstTokenDelivered"], timestamp_hash(tokens.first), "#{path}.firstTokenDelivered")
      ordered_at!(request_accepted, first_token_time, "#{path} acceptance/first token")

      if cancelled
        equal_at!(done["reason"], "cancelled", "#{path}.terminal.reason")
        validate_cancellation_capture!(capture, path, first_token_time, terminal_delivered)
      else
        fail_at("#{path}.terminal.reason", "unexpectedly reports cancellation") if done["reason"] == "cancelled"
        equal_at!(capture["cancellation"], nil, "#{path}.cancellation")
      end
      capture
    end

    def validate_cancellation_capture!(capture, path, first_token_time, terminal_delivered)
      cancellation = object!(capture["cancellation"], "#{path}.cancellation")
      stream_observed = timestamp!(cancellation["streamObserved"], "#{path}.cancellation.streamObserved")
      cancel_invoked = timestamp!(cancellation["cancelInvoked"], "#{path}.cancellation.cancelInvoked")
      cancel_returned = timestamp!(cancellation["cancelReturned"], "#{path}.cancellation.cancelReturned")
      cancellation_terminal = timestamp!(
        cancellation["terminalDelivered"],
        "#{path}.cancellation.terminalDelivered"
      )
      equal_at!(cancellation["streamObserved"], capture["firstTokenDelivered"], "#{path}.cancellation.streamObserved")
      equal_at!(cancellation["terminalDelivered"], capture["terminalDelivered"], "#{path}.cancellation.terminalDelivered")
      ordered_at!(first_token_time, stream_observed, "#{path} stream observation")
      ordered_at!(stream_observed, cancel_invoked, "#{path} cancel invocation")
      ordered_at!(cancel_invoked, cancel_returned, "#{path} cancel return")
      ordered_at!(cancel_invoked, cancellation_terminal, "#{path} cancellation terminal")
      equal_at!(cancellation_terminal, terminal_delivered, "#{path} cancellation terminal timestamp")
      latency = nonnegative_number!(cancellation["latencyMs"], "#{path}.cancellation.latencyMs")
      expected_latency = cancellation_terminal.fetch("monotonicMs") - cancel_invoked.fetch("monotonicMs")
      approximately_equal_at!(latency, expected_latency, "#{path}.cancellation.latencyMs")
      fail_at("#{path}.cancellation.latencyMs", "must be strictly under 200 ms") unless latency < STRICT_CANCELLATION_LIMIT_MS
    end

    def validate_stats!(value, path)
      stats = object!(value, path)
      nonnegative_number!(stats["prefillMs"], "#{path}.prefillMs")
      nonnegative_number!(stats["decodeMs"], "#{path}.decodeMs")
      nonnegative_integer!(stats["promptTokens"], "#{path}.promptTokens")
      nonnegative_integer!(stats["generatedTokens"], "#{path}.generatedTokens")
      nonnegative_integer!(stats["peakRssBytes"], "#{path}.peakRssBytes")
      stats
    end

    def validate_diagnostics!(value, path)
      diagnostics = object!(value, path)
      equal_at!(diagnostics["requestedAccelerator"], "cpu", "#{path}.requestedAccelerator")
      equal_at!(diagnostics["selectedAccelerator"], "cpu", "#{path}.selectedAccelerator")
      equal_at!(diagnostics["offloadedLayers"], 0, "#{path}.offloadedLayers")
      equal_at!(diagnostics["kqvOffloaded"], false, "#{path}.kqvOffloaded")
      positive_integer!(diagnostics["contextSize"], "#{path}.contextSize")
      positive_integer!(diagnostics["batchSize"], "#{path}.batchSize")
      positive_integer!(diagnostics["modelLayers"], "#{path}.modelLayers")
      nonnegative_integer!(diagnostics["peakRssBytes"], "#{path}.peakRssBytes")
      diagnostics
    end

    def validate_memory_markers!(cycle, path, settle_ms)
      expected_phases = %w[
        pre-load
        post-load
        post-load-diagnostics
        post-terminal
        post-terminal-diagnostics
        pre-unload
        post-unload
        post-unload-settle
      ]
      markers = exact_array_length!(cycle["markers"], expected_phases.length, "#{path}.markers")
      parsed = markers.each_with_index.map do |marker_value, index|
        marker = object!(marker_value, "#{path}.markers[#{index}]")
        equal_at!(marker["phase"], expected_phases.fetch(index), "#{path}.markers[#{index}].phase")
        timestamp!(marker, "#{path}.markers[#{index}]")
      end
      parsed.each_cons(2) do |left, right|
        ordered_at!(left, right, "#{path} marker order")
      end
      durations = object!(cycle["lifecycleDurationsMs"], "#{path}.lifecycleDurationsMs")
      load_duration = nonnegative_number!(durations["load"], "#{path}.lifecycleDurationsMs.load")
      unload_duration = nonnegative_number!(durations["unload"], "#{path}.lifecycleDurationsMs.unload")
      approximately_equal_at!(
        load_duration,
        parsed.fetch(1).fetch("monotonicMs") - parsed.fetch(0).fetch("monotonicMs"),
        "#{path}.lifecycleDurationsMs.load"
      )
      approximately_equal_at!(
        unload_duration,
        parsed.fetch(6).fetch("monotonicMs") - parsed.fetch(5).fetch("monotonicMs"),
        "#{path}.lifecycleDurationsMs.unload"
      )
      observed_settle = parsed.fetch(7).fetch("monotonicMs") - parsed.fetch(6).fetch("monotonicMs")
      if observed_settle + 0.001 < settle_ms
        fail_at("#{path}.markers", "post-unload settle is shorter than lifecycleSettleMs")
      end
      capture = object!(cycle["generation"], "#{path}.generation")
      generation_start = timestamp!(capture["generateInvoked"], "#{path}.generation.generateInvoked")
      generation_terminal = timestamp!(capture["terminalDelivered"], "#{path}.generation.terminalDelivered")
      ordered_at!(parsed.fetch(2), generation_start, "#{path} diagnostics/generation order")
      ordered_at!(generation_terminal, parsed.fetch(3), "#{path} terminal marker order")
    end

    def validate_benchmark_derivation!(value, capture, path)
      derived = object!(value, path)
      stats = capture.dig("terminal", "stats")
      generated_tokens = stats.fetch("generatedTokens")
      decode_ms = stats.fetch("decodeMs")
      native_ms = stats.fetch("prefillMs") + decode_ms
      e2e_ms = capture.dig("terminalDelivered", "monotonicMs") -
               capture.dig("requestAccepted", "monotonicMs")
      first = capture["firstTokenDelivered"]
      expected = {
        "decodeTokensPerSecond" => decode_ms.positive? ? (generated_tokens * 1000.0 / decode_ms) : nil,
        "nativeInferenceTokensPerSecond" => native_ms.positive? ? (generated_tokens * 1000.0 / native_ms) : nil,
        "endToEndTokensPerSecond" => e2e_ms.positive? ? (generated_tokens * 1000.0 / e2e_ms) : nil,
        "timeToFirstDeliveredFragmentMs" => first.nil? ? nil : first.fetch("monotonicMs") - capture.dig("requestAccepted", "monotonicMs")
      }
      expected.each do |key, expected_value|
        actual = derived[key]
        if expected_value.nil?
          equal_at!(actual, nil, "#{path}.#{key}")
        else
          nonnegative_number!(actual, "#{path}.#{key}")
          approximately_equal_at!(actual, expected_value, "#{path}.#{key}")
        end
      end
      derived
    end

    def build_summary(manifest, suites)
      {
        "schemaVersion" => 1,
        "validator" => "pocketlm-m4-artifacts-v2",
        "status" => "passed",
        "workloadVersion" => @expected_workload_version,
        "selectedSuite" => @expected_suite,
        "runId" => manifest.fetch("runId"),
        "collectorNonce" => @expected_collector_nonce,
        "sourceBinding" => {
          "appCommit" => @expected_rc,
          "modelSha256" => @expected_model_sha256,
          "modelSourceFilename" => manifest.dig("model", "sourceFilename"),
          "modelInstalledFilename" => manifest.dig("model", "installedFilename")
        },
        "scope" => {
          "resultClass" => manifest.dig("scope", "resultClass"),
          "platform" => manifest.dig("app", "platform"),
          "platformVersion" => manifest.dig("app", "platformVersion"),
          "buildMode" => manifest.dig("app", "buildMode"),
          "accelerator" => manifest.dig("sessionConfig", "accelerator"),
          "physicalDeviceClaim" => false
        },
        "validatedArtifacts" => @expected_files,
        "suites" => suites
      }
    end

    def describe(values)
      values.each_with_index do |value, index|
        nonnegative_number!(value, "summary series[#{index}]")
      end
      if values.empty?
        return {
          "count" => 0,
          "min" => nil,
          "median" => nil,
          "mean" => nil,
          "p95" => nil,
          "max" => nil
        }
      end
      sorted = values.sort
      count = sorted.length
      median = if count.odd?
                 sorted.fetch(count / 2)
               else
                 (sorted.fetch((count / 2) - 1) + sorted.fetch(count / 2)) / 2.0
               end
      p95_index = [(0.95 * count).ceil - 1, 0].max
      {
        "count" => count,
        "min" => sorted.first,
        "median" => median,
        "mean" => sorted.sum(0.0) / count,
        "p95" => sorted.fetch(p95_index),
        "max" => sorted.last
      }
    end

    def object!(value, path)
      fail_at(path, "must be an object") unless value.is_a?(Hash)
      value
    end

    def array!(value, path)
      fail_at(path, "must be an array") unless value.is_a?(Array)
      value
    end

    def exact_array_length!(value, length, path)
      array = array!(value, path)
      fail_at(path, "must contain exactly #{length} entries") unless array.length == length
      array
    end

    def nonempty_string!(value, path)
      fail_at(path, "must be a nonempty string") unless value.is_a?(String) && !value.empty?
      fail_at(path, "must be valid UTF-8") unless value.valid_encoding?
      value
    end

    def basename_string!(value, path)
      string = nonempty_string!(value, path)
      fail_at(path, "must be a filename, not a path") unless File.basename(string) == string && ![".", ".."].include?(string)
      string
    end

    def safe_run_id!(value, path)
      string = nonempty_string!(value, path)
      fail_at(path, "is not a safe run ID") unless string.match?(/\A[a-z0-9][a-z0-9._-]{0,127}\z/)
      string
    end

    def positive_int32!(value, path)
      positive_integer!(value, path)
      fail_at(path, "must fit signed 32-bit range") if value > MAX_INT32
      value
    end

    def positive_integer!(value, path)
      fail_at(path, "must be a positive integer") unless value.is_a?(Integer) && value.positive?
      value
    end

    def nonnegative_integer!(value, path)
      fail_at(path, "must be a nonnegative integer") unless value.is_a?(Integer) && value >= 0
      value
    end

    def nonnegative_number!(value, path)
      unless value.is_a?(Numeric) && value.finite? && value >= 0
        fail_at(path, "must be a finite nonnegative number")
      end
      value
    end

    def iso_time!(value, path)
      string = nonempty_string!(value, path)
      Time.iso8601(string)
      string
    rescue ArgumentError
      fail_at(path, "must be an ISO-8601 timestamp")
    end

    def timestamp!(value, path)
      timestamp = object!(value, path)
      iso_time!(timestamp["wallClock"], "#{path}.wallClock")
      nonnegative_number!(timestamp["monotonicMs"], "#{path}.monotonicMs")
      timestamp_hash(timestamp)
    end

    def timestamp_hash(value)
      {
        "wallClock" => value.fetch("wallClock"),
        "monotonicMs" => value.fetch("monotonicMs")
      }
    end

    def ordered_at!(left, right, path)
      unless left.fetch("monotonicMs") <= right.fetch("monotonicMs")
        fail_at(path, "has decreasing monotonic timestamps")
      end
    end

    def unique_at!(values, path, expected_count: values.length)
      actual = values.uniq.length
      fail_at(path, "must contain #{expected_count} unique value(s), found #{actual}") unless actual == expected_count
    end

    def approximately_equal_at!(actual, expected, path)
      tolerance = [1e-6, expected.abs * 1e-9].max
      fail_at(path, "does not match its raw inputs") unless (actual - expected).abs <= tolerance
    end

    def equal_at!(actual, expected, path)
      fail_at(path, "does not match the frozen qualification schema") unless actual == expected
    end

    def fail_at(path, message)
      raise Error, "#{path}: #{message}"
    end
  end
end
