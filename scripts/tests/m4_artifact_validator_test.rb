# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../lib/m4_artifacts"
require_relative "m4_artifact_fixture"

class M4ArtifactValidatorTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("pocketlm-m4-validator-", "/tmp")
    write_fixture
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  def validator(
    expected_rc: M4ArtifactFixture::RC_COMMIT,
    expected_workload_version: @workload_version,
    expected_suite: @suite
  )
    PocketLMM4Artifacts::Validator.new(
      run_directory: @run_directory,
      expected_rc: expected_rc,
      expected_model_sha256: M4ArtifactFixture::MODEL_SHA256,
      expected_collector_nonce: M4ArtifactFixture::COLLECTOR_NONCE,
      expected_workload_version: expected_workload_version,
      expected_suite: expected_suite
    )
  end

  def test_validates_v1_all_fixture_and_derives_suite_summaries
    raw_reproducibility = JSON.parse(
      File.binread(File.join(@run_directory, "reproducibility.json"))
    )
    first_capture = raw_reproducibility.dig("runs", 0, "generation")
    assert_equal 1, first_capture.dig("rawEvents", 0, "tokenCount")
    assert_equal 2, first_capture.dig("terminal", "stats", "generatedTokens")

    summary = validator.validate!

    assert_equal "passed", summary.fetch("status")
    assert_equal "pocketlm-m4-artifacts-v2", summary.fetch("validator")
    assert_equal M4ArtifactFixture::WORKLOAD_V1, summary.fetch("workloadVersion")
    assert_equal "all", summary.fetch("selectedSuite")
    assert_equal M4ArtifactFixture::COLLECTOR_NONCE, summary.fetch("collectorNonce")
    assert_equal M4ArtifactFixture::RC_COMMIT, summary.dig("sourceBinding", "appCommit")
    assert_equal 100, summary.dig("suites", "utf8", "generationCount")
    assert_equal 20, summary.dig("suites", "cancellation", "trialCount")
    assert_equal 10, summary.dig("suites", "cancellation", "latencyMs", "min")
    assert_equal 19.5, summary.dig("suites", "cancellation", "latencyMs", "median")
    assert_equal 28, summary.dig("suites", "cancellation", "latencyMs", "p95")
    assert_equal 29, summary.dig("suites", "cancellation", "latencyMs", "max")
    assert_equal 15, summary.dig("suites", "benchmark", "measuredRunCount")
    assert_equal 3, summary.dig(
      "suites", "benchmark", "throughput", "decodeTokensPerSecond",
      "perPrompt", "bench-1", "count"
    )
  end

  def test_validates_v2_all_fixture_with_512_at_every_benchmark_layer
    write_fixture(workload_version: M4ArtifactFixture::WORKLOAD_V2)

    summary = validator.validate!
    manifest = read_document("manifest.json")
    benchmark = read_document("benchmark.json")

    assert_equal M4ArtifactFixture::WORKLOAD_V2, summary.fetch("workloadVersion")
    assert_equal "all", summary.fetch("selectedSuite")
    assert_equal 512, manifest.dig("fixedParameters", "benchmark", "maxTokens")
    assert_equal 512, benchmark.dig("params", "maxTokens")
    assert_equal 512, benchmark.dig("excludedWarmup", "params", "maxTokens")
    assert benchmark.fetch("rawRuns").all? { |run|
      run.dig("generation", "params", "maxTokens") == 512
    }
  end

  def test_validates_v1_memory_fixture_as_an_exact_three_file_profile
    write_fixture(
      workload_version: M4ArtifactFixture::WORKLOAD_V1,
      suite: "memory"
    )

    summary = validator.validate!

    assert_equal M4ArtifactFixture::WORKLOAD_V1, summary.fetch("workloadVersion")
    assert_equal "memory", summary.fetch("selectedSuite")
    assert_equal %w[COMPLETE.json manifest.json memory.json], summary.fetch("validatedArtifacts")
    assert_equal ["memory"], summary.fetch("suites").keys
    assert_equal %w[COMPLETE.json manifest.json memory.json], Dir.children(@run_directory).sort
  end

  def test_validates_v2_memory_fixture_as_an_exact_three_file_profile
    write_fixture(
      workload_version: M4ArtifactFixture::WORKLOAD_V2,
      suite: "memory"
    )

    summary = validator.validate!
    manifest = read_document("manifest.json")

    assert_equal M4ArtifactFixture::WORKLOAD_V2, summary.fetch("workloadVersion")
    assert_equal "memory", summary.fetch("selectedSuite")
    assert_equal ["memory"], manifest.fetch("selectedSuites")
    assert_equal 512, manifest.dig("fixedParameters", "benchmark", "maxTokens")
  end

  def test_rejects_an_unknown_requested_workload_version
    error = assert_raises(PocketLMM4Artifacts::Error) do
      validator(expected_workload_version: "m4-workload-v3")
    end

    assert_includes error.message, "expected workload version"
  end

  def test_rejects_an_unknown_requested_suite
    error = assert_raises(PocketLMM4Artifacts::Error) do
      validator(expected_suite: "benchmark")
    end

    assert_includes error.message, "expected suite"
  end

  def test_rejects_a_missing_workload_version
    mutate("manifest.json") { |document| document.delete("workloadVersion") }

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "manifest.json.workloadVersion"
  end

  def test_rejects_a_requested_and_observed_workload_mismatch
    error = assert_raises(PocketLMM4Artifacts::Error) do
      validator(expected_workload_version: M4ArtifactFixture::WORKLOAD_V2).validate!
    end

    assert_includes error.message, "manifest.json.workloadVersion"
  end

  def test_rejects_a_mixed_workload_version_set
    write_fixture(workload_version: M4ArtifactFixture::WORKLOAD_V2)
    mutate("benchmark.json") do |document|
      document["workloadVersion"] = M4ArtifactFixture::WORKLOAD_V1
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "benchmark.json.workloadVersion"
  end

  def test_rejects_v2_manifest_benchmark_max_tokens_from_v1
    write_fixture(workload_version: M4ArtifactFixture::WORKLOAD_V2)
    mutate("manifest.json") do |document|
      document.dig("fixedParameters", "benchmark")["maxTokens"] = 128
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "manifest.json.fixedParameters.benchmark"
  end

  def test_rejects_v2_benchmark_header_max_tokens_from_v1
    write_fixture(workload_version: M4ArtifactFixture::WORKLOAD_V2)
    mutate("benchmark.json") do |document|
      document.fetch("params")["maxTokens"] = 128
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "benchmark.json.params"
  end

  def test_rejects_v2_benchmark_warmup_max_tokens_from_v1
    write_fixture(workload_version: M4ArtifactFixture::WORKLOAD_V2)
    mutate("benchmark.json") do |document|
      document.dig("excludedWarmup", "params")["maxTokens"] = 128
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "benchmark.json.excludedWarmup.params"
  end

  def test_rejects_v2_nested_measured_generation_max_tokens_from_v1
    write_fixture(workload_version: M4ArtifactFixture::WORKLOAD_V2)
    mutate("benchmark.json") do |document|
      document.dig("rawRuns", 14, "generation", "params")["maxTokens"] = 128
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "benchmark.json.rawRuns[14].generation.params"
  end

  def test_rejects_v2_nested_memory_generation_max_tokens
    write_fixture(
      workload_version: M4ArtifactFixture::WORKLOAD_V2,
      suite: "memory"
    )
    mutate("memory.json") do |document|
      document.dig("cycles", 10, "generation", "params")["maxTokens"] = 512
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "memory.json.cycles[10].generation.params"
  end

  def test_rejects_missing_or_unexpected_files_for_the_memory_profile
    write_fixture(suite: "memory")
    File.write(File.join(@run_directory, "benchmark.json"), "{}\n")

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "unexpected entries"

    write_fixture(suite: "memory")
    FileUtils.rm_f(File.join(@run_directory, "memory.json"))

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "is missing memory.json"
  end

  def test_rejects_wrong_memory_suite_metadata
    checks = [
      ["manifest.json", "manifest.json.selectedSuite", lambda { |document|
        document["selectedSuite"] = "all"
      }],
      ["manifest.json", "manifest.json.selectedSuites", lambda { |document|
        document["selectedSuites"] = M4ArtifactFixture::SUITES
      }],
      ["COMPLETE.json", "COMPLETE.json.suite", lambda { |document|
        document["suite"] = "all"
      }]
    ]

    checks.each do |filename, expected_path, mutation|
      write_fixture(suite: "memory")
      mutate(filename, &mutation)
      error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
      assert_includes error.message, expected_path
    end
  end

  def test_rejects_wrong_release_candidate_binding
    error = assert_raises(PocketLMM4Artifacts::Error) do
      validator(expected_rc: "d" * 40).validate!
    end

    assert_includes error.message, "app.appCommit"
  end

  def test_rejects_wrong_collector_nonce_binding
    mutate("COMPLETE.json") do |document|
      document["collectorNonce"] = "d" * 32
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "COMPLETE.json.collectorNonce"
  end

  def test_rejects_private_absolute_paths_before_summarizing
    mutate("manifest.json") do |document|
      document.fetch("app")["buildSource"] = "/Users/example/private/PocketLM"
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "private absolute path"
  end

  def test_rejects_credential_like_fields_before_summarizing
    mutate("manifest.json") do |document|
      document.fetch("app")["sentryDsn"] = "https://public-key@example.invalid/1"
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "credential-like field name"
  end

  def test_rejects_tampered_reconstructed_output
    mutate("utf8.json") do |document|
      document.fetch("cases").first.fetch("generation")["outputUtf8Hex"] = "00"
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "outputUtf8Hex"
  end

  def test_rejects_cancellation_at_the_strict_boundary
    latencies = (10..28).to_a + [200]
    write_fixture(cancellation_latencies: latencies)

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "strictly under 200 ms"
  end

  def test_rejects_false_app_memory_ceiling_claim
    mutate("memory.json") do |document|
      document["memoryCeilingAssertedByApp"] = true
    end

    error = assert_raises(PocketLMM4Artifacts::Error) { validator.validate! }
    assert_includes error.message, "memoryCeilingAssertedByApp"
  end

  def test_cli_refuses_to_overwrite_summary_without_explicit_flag
    output = File.join(@directory, "summary.json")
    command = [
      RbConfig.ruby,
      File.expand_path("../validate-m4-artifacts.rb", __dir__),
      @run_directory,
      "--expected-rc", M4ArtifactFixture::RC_COMMIT,
      "--expected-model-sha256", M4ArtifactFixture::MODEL_SHA256,
      "--expected-collector-nonce", M4ArtifactFixture::COLLECTOR_NONCE,
      "--expected-workload-version", M4ArtifactFixture::WORKLOAD_V1,
      "--expected-suite", "all",
      "--output", output
    ]

    _stdout, stderr, status = Open3.capture3(*command)
    assert status.success?, stderr
    first = File.binread(output)

    _stdout, stderr, status = Open3.capture3(*command)
    refute status.success?
    assert_includes stderr, "--overwrite"
    assert_equal first, File.binread(output)

    _stdout, stderr, status = Open3.capture3(*command, "--overwrite")
    assert status.success?, stderr
    assert_equal "passed", JSON.parse(File.binread(output)).fetch("status")
  end

  def test_cli_validates_the_v2_memory_profile
    write_fixture(
      workload_version: M4ArtifactFixture::WORKLOAD_V2,
      suite: "memory"
    )
    command = [
      RbConfig.ruby,
      File.expand_path("../validate-m4-artifacts.rb", __dir__),
      @run_directory,
      "--expected-rc", M4ArtifactFixture::RC_COMMIT,
      "--expected-model-sha256", M4ArtifactFixture::MODEL_SHA256,
      "--expected-collector-nonce", M4ArtifactFixture::COLLECTOR_NONCE,
      "--expected-workload-version", M4ArtifactFixture::WORKLOAD_V2,
      "--expected-suite", "memory"
    ]

    stdout, stderr, status = Open3.capture3(*command)

    assert status.success?, stderr
    summary = JSON.parse(stdout)
    assert_equal M4ArtifactFixture::WORKLOAD_V2, summary.fetch("workloadVersion")
    assert_equal "memory", summary.fetch("selectedSuite")
    assert_equal ["memory"], summary.fetch("suites").keys
  end

  def test_cli_requires_explicit_workload_version_and_suite
    command = [
      RbConfig.ruby,
      File.expand_path("../validate-m4-artifacts.rb", __dir__),
      @run_directory,
      "--expected-rc", M4ArtifactFixture::RC_COMMIT,
      "--expected-model-sha256", M4ArtifactFixture::MODEL_SHA256,
      "--expected-collector-nonce", M4ArtifactFixture::COLLECTOR_NONCE
    ]

    _stdout, stderr, status = Open3.capture3(*command)

    assert_equal 2, status.exitstatus
    assert_includes stderr, "--expected-workload-version"
    assert_includes stderr, "--expected-suite"
  end

  private

  def write_fixture(
    workload_version: M4ArtifactFixture::WORKLOAD_V1,
    suite: "all",
    cancellation_latencies: (10..29).to_a
  )
    fixture = M4ArtifactFixture.new(
      @directory,
      cancellation_latencies: cancellation_latencies,
      workload_version: workload_version,
      suite: suite
    )
    FileUtils.remove_entry(fixture.run_directory) if File.exist?(fixture.run_directory)
    @run_directory = fixture.write!
    @workload_version = workload_version
    @suite = suite
  end

  def read_document(filename)
    JSON.parse(File.binread(File.join(@run_directory, filename)))
  end

  def mutate(filename)
    path = File.join(@run_directory, filename)
    document = read_document(filename)
    yield document
    File.write(path, JSON.pretty_generate(document) + "\n")
  end
end
