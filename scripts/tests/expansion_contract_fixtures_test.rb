# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "expansion_contract_fixture_support"

class ExpansionContractFixturesTest < Minitest::Test
  Support = PocketLMExpansionContractFixtures

  MODEL_ID = "fixture-model"
  ARTIFACT_SHA256 = "a" * 64
  PUBLICATION_ID = "b" * 32
  OPERATION_ID = "c" * 32
  LARGE_REVISION = "9007199254740993"

  def test_fixture_corpus_is_closed_hashed_and_complete
    summary = Support.verify!

    assert_equal 10, summary.fetch("families").length
    assert_operator summary.fetch("fileCount"), :>=, 11
    assert_operator summary.fetch("caseCount"), :>, 0
  end

  def test_strict_json_rejects_duplicate_keys_at_every_object_depth
    assert_equal({ "value" => 1 }, Support.strict_json_parse('{"value":1}', label: "test"))

    root_error = assert_raises(Support::Error) do
      Support.strict_json_parse('{"value":1,"value":2}', label: "root duplicate")
    end
    assert_match(/duplicate object key.*value/, root_error.message)

    nested_error = assert_raises(Support::Error) do
      Support.strict_json_parse(
        '{"outer":{"value":1,"value":2}}',
        label: "nested duplicate"
      )
    end
    assert_match(/duplicate object key.*value/, nested_error.message)
  end

  def test_strict_json_preserves_bom_and_utf8_rejection
    assert_raises(Support::Error) do
      Support.strict_json_parse("\xEF\xBB\xBF{}".b, label: "BOM")
    end
    assert_raises(Support::Error) do
      Support.strict_json_parse("{\"value\":\"\xFF\"}".b, label: "invalid UTF-8")
    end
  end

  def test_indexed_sidecar_duplicate_key_is_rejected_even_after_rehash
    with_temp_corpus do |root|
      relative = "bytes/catalog-v2-one-model.json"
      path = File.join(root, relative)
      bytes = File.binread(path)
      File.binwrite(path, bytes.sub(/\A\{/, '{"schemaVersion":2,'))
      reindex_file(root, relative)

      error = assert_raises(Support::Error) { Support.verify!(root: root) }
      assert_match(/duplicate object key.*schemaVersion/, error.message)
      refute_match(/SHA-256 mismatch/, error.message)
    end
  end

  def test_canonical_timestamp_uses_exact_utc_seconds_and_proleptic_gregorian
    assert Support.canonical_timestamp?("0001-01-01T00:00:00Z")
    assert Support.canonical_timestamp?("2000-02-29T23:59:59Z")
    assert Support.canonical_timestamp?("9999-12-31T23:59:59Z")

    refute Support.canonical_timestamp?("0000-01-01T00:00:00Z")
    refute Support.canonical_timestamp?("1500-02-29T00:00:00Z")
    refute Support.canonical_timestamp?("2026-02-29T00:00:00Z")
    refute Support.canonical_timestamp?("2026-08-23T24:00:00Z")
    refute Support.canonical_timestamp?("2026-08-23T00:00:60Z")
    refute Support.canonical_timestamp?("2026-08-23T00:00:00.000Z")
    refute Support.canonical_timestamp?("2026-08-22T17:00:00-07:00")
    refute Support.canonical_timestamp?("2026-8-23T00:00:00Z")
  end

  def test_decimal_revisions_are_canonical_and_compare_without_numeric_conversion
    assert Support.canonical_decimal_revision?("0")
    assert Support.canonical_decimal_revision?(LARGE_REVISION)
    assert Support.canonical_decimal_revision?("9" * 1_024)
    refute Support.canonical_decimal_revision?("")
    refute Support.canonical_decimal_revision?("00")
    refute Support.canonical_decimal_revision?("+1")
    refute Support.canonical_decimal_revision?(" 1")
    refute Support.canonical_decimal_revision?(1)

    assert_equal(-1, Support.compare_decimal_revisions("9", "10"))
    assert_equal 0, Support.compare_decimal_revisions(LARGE_REVISION, LARGE_REVISION)
    assert_equal 1, Support.compare_decimal_revisions("1" + ("0" * 100), "9" * 100)
    assert_raises(Support::Error) { Support.compare_decimal_revisions("01", "1") }
  end

  def test_decimal_revision_increment_is_unbounded_checked_string_arithmetic
    assert_equal "1", Support.increment_decimal_revision("0")
    assert_equal "10", Support.increment_decimal_revision("9")
    assert_equal "1000", Support.increment_decimal_revision("999")
    assert_equal "1#{'0' * 1_024}", Support.increment_decimal_revision("9" * 1_024)
    assert_equal "9007199254740994", Support.increment_decimal_revision(LARGE_REVISION)
    assert_raises(Support::Error) { Support.increment_decimal_revision("09") }
  end

  def test_lowercase_identifier_and_digest_grammars_are_exact
    assert Support.canonical_lowercase_id?(PUBLICATION_ID)
    refute Support.canonical_lowercase_id?("0" * 32)
    refute Support.canonical_lowercase_id?("B" * 32)
    refute Support.canonical_lowercase_id?("b" * 31)

    assert Support.canonical_lowercase_digest?(ARTIFACT_SHA256)
    assert Support.canonical_lowercase_digest?("0" * 64)
    refute Support.canonical_lowercase_digest?("A" * 64)
    refute Support.canonical_lowercase_digest?("a" * 63)
  end

  def test_runtime_fingerprint_matches_the_exact_nul_delimited_vector
    fields = {
      "modelId" => MODEL_ID,
      "artifactSha256" => ARTIFACT_SHA256,
      "publicationId" => PUBLICATION_ID,
      "contextSize" => 2_048,
      "requestedAccelerator" => "auto",
      "gpuLayers" => 0,
      "policyProfileVersion" => 1
    }

    assert_equal(
      "b5643a0e85b94fae0f9d86b71ff8227110b52ea7c58ab8dc042e1b731963510d",
      Support.runtime_fingerprint(fields)
    )
    assert_raises(Support::Error) do
      Support.runtime_fingerprint(fields.merge("modelId" => "fixture\0model"))
    end
    assert_raises(Support::Error) do
      Support.runtime_fingerprint(fields.merge("contextSize" => 0))
    end
    assert_raises(Support::Error) do
      Support.runtime_fingerprint(fields.merge("gpuLayers" => -1))
    end
    assert_raises(Support::Error) do
      Support.runtime_fingerprint(fields.merge("extra" => "not hashed"))
    end
  end

  def test_all_command_argument_digests_match_the_exact_field_orders
    vectors = {
      "startInstall" => [
        { "method" => "startInstall", "modelId" => MODEL_ID, "expectedRevision" => LARGE_REVISION },
        "8a9076ad3334152f0ee43e1e14962fa2c5b6af4290aa5ac581a3281f0e292323"
      ],
      "pauseInstall" => [
        control_command("pauseInstall"),
        "8427b890da8415872b5c11ecb347c10f05448f70ae3855c630586e45d7939782"
      ],
      "resumeInstall" => [
        control_command("resumeInstall"),
        "ab4f9b310d358ddfffcb046555322d35fac734038af8e5702bfc6d1583c6c0b4"
      ],
      "cancelInstall" => [
        control_command("cancelInstall"),
        "ef8a33356da28a849ef4f12a4ba15373b3673427330f7bf579e9a994c411cc7f"
      ],
      "deleteInstallation" => [
        {
          "method" => "deleteInstallation",
          "modelId" => MODEL_ID,
          "expectedRevision" => LARGE_REVISION
        },
        "dac5566820e6c2792683b9833fa9e2daebc30056a96651dfa884ed322f254776"
      ],
      "setSelectedPreference" => [
        {
          "method" => "setSelectedPreference",
          "modelId" => MODEL_ID,
          "origin" => "manual",
          "expectedRevision" => LARGE_REVISION
        },
        "5aadbffd3b5f8fdfd601c9913545c09f6b9cccf6c5f38aca4c1037f8a9f48ba5"
      ]
    }

    assert_equal Support::COMMAND_FIELDS.keys.sort, vectors.keys.sort
    vectors.each_value do |input, expected|
      assert_equal expected, Support.command_argument_digest(input)
    end
  end

  def test_command_digest_rejects_noncanonical_or_unhashed_arguments
    assert_raises(Support::Error) do
      Support.command_argument_digest(control_command("pauseInstall").merge("operationId" => "0" * 32))
    end
    assert_raises(Support::Error) do
      Support.command_argument_digest(
        {
          "method" => "setSelectedPreference",
          "modelId" => MODEL_ID,
          "origin" => "automatic",
          "expectedRevision" => "1"
        }
      )
    end
    assert_raises(Support::Error) do
      Support.command_argument_digest(
        {
          "method" => "startInstall",
          "modelId" => MODEL_ID,
          "expectedRevision" => "01"
        }
      )
    end
    assert_raises(Support::Error) do
      Support.command_argument_digest(
        {
          "method" => "startInstall",
          "modelId" => MODEL_ID,
          "expectedRevision" => "1",
          "commandId" => "d" * 32
        }
      )
    end
  end

  def test_public_preference_command_digest_accepts_only_manual_and_recommended_origins
    base = {
      "method" => "setSelectedPreference",
      "modelId" => MODEL_ID,
      "expectedRevision" => LARGE_REVISION
    }
    assert_equal(
      "5aadbffd3b5f8fdfd601c9913545c09f6b9cccf6c5f38aca4c1037f8a9f48ba5",
      Support.command_argument_digest(base.merge("origin" => "manual"))
    )
    assert_equal(
      "80050ad565839867e4dad976501d19522a3ba2ead94f120b6b084a62a00c30b6",
      Support.command_argument_digest(base.merge("origin" => "recommended"))
    )

    %w[migrated fallback].each do |internal_origin|
      error = assert_raises(Support::Error) do
        Support.command_argument_digest(base.merge("origin" => internal_origin))
      end
      assert_match(/public origin/, error.message)
    end
  end

  def test_policy_recommendation_uses_catalog_rank_and_exact_ram_boundaries
    models = [
      {
        "id" => "small-model",
        "minTotalRamBytes" => 2_147_483_648,
        "recommendedRamBytes" => 4_294_967_296
      },
      {
        "id" => "large-model",
        "minTotalRamBytes" => 4_294_967_296,
        "recommendedRamBytes" => 6_442_450_944
      }
    ]

    assert_equal(
      { "modelId" => nil, "claimDeviceFit" => false },
      Support.policy_recommendation(recommendation_input(models, 2_147_483_647))
    )
    assert_equal(
      { "modelId" => "small-model", "claimDeviceFit" => true },
      Support.policy_recommendation(recommendation_input(models, 2_147_483_648))
    )
    assert_equal(
      { "modelId" => "small-model", "claimDeviceFit" => true },
      Support.policy_recommendation(recommendation_input(models, 4_294_967_296))
    )
    assert_equal(
      { "modelId" => "large-model", "claimDeviceFit" => true },
      Support.policy_recommendation(recommendation_input(models, 6_442_450_944))
    )
    assert_equal(
      { "modelId" => nil, "claimDeviceFit" => false },
      Support.policy_recommendation(
        recommendation_input(models, 8_589_934_592).merge("probeStatus" => "missing")
      )
    )
  end

  def test_policy_thread_count_covers_ios_android_and_unknown_frequency_paths
    assert_equal(
      { "value" => 4 },
      Support.policy_n_threads(
        {
          "kind" => "n_threads",
          "probeStatus" => "valid",
          "platform" => "ios",
          "activeProcessorCount" => 8
        }
      )
    )
    assert_equal(
      { "value" => 2 },
      Support.policy_n_threads(
        {
          "kind" => "n_threads",
          "probeStatus" => "valid",
          "platform" => "android",
          "activeProcessorCount" => 3,
          "maxFrequencyKhzByCpu" => [100, 90, 89]
        }
      )
    )
    assert_equal(
      { "value" => 3 },
      Support.policy_n_threads(
        {
          "kind" => "n_threads",
          "probeStatus" => "valid",
          "platform" => "android",
          "activeProcessorCount" => 3,
          "maxFrequencyKhzByCpu" => [100, nil, 90]
        }
      )
    )
    assert_equal(
      { "value" => 1 },
      Support.policy_n_threads(
        {
          "kind" => "n_threads",
          "probeStatus" => "valid",
          "platform" => "android",
          "activeProcessorCount" => 1,
          "maxFrequencyKhzByCpu" => [100, 100, 100, 100, 100, 100, 100, 100]
        }
      )
    )
  end

  def test_accepted_sidecar_semantic_mutations_fail_after_index_rehash
    assert_json_mutation_rejected(
      "bytes/catalog-v2-two-models.json",
      /frozen model identity, policy, or template facts/
    ) do |document|
      document.fetch("models").last["recommendedRamBytes"] = 6_442_450_943
    end

    assert_json_mutation_rejected(
      "bytes/installation-commit-0.5b-v1.json",
      /manifest\/model agreement/
    ) do |document|
      document["publicationId"] = "fedcba9876543210fedcba9876543210"
    end

    assert_json_mutation_rejected(
      "bytes/migration-journal-prepared-v1.json",
      /preferenceBytesSha256/
    ) do |document|
      document["preferenceBytesSha256"] = "0" * 64
    end

    assert_json_mutation_rejected(
      "bytes/manager-state-empty-v1.json",
      /keys must be exactly/
    ) do |document|
      document["nativeResumeBlob"] = "forbidden"
    end
  end

  def test_coherently_rehashed_migrated_preference_cannot_change_to_fallback
    with_temp_corpus do |root|
      preference_relative = "bytes/selected-preference-migrated-v1.json"
      preference_path = File.join(root, preference_relative)
      preference = JSON.parse(File.binread(preference_path))
      preference["origin"] = "fallback"
      File.binwrite(preference_path, JSON.generate(preference) << "\n")
      reindex_file(root, preference_relative)
      refresh_raw_digest_claims(root, preference_relative)

      preference_bytes = File.binread(preference_path).force_encoding(Encoding::UTF_8)
      journal_relative = "bytes/migration-journal-prepared-v1.json"
      journal_path = File.join(root, journal_relative)
      journal = JSON.parse(File.binread(journal_path))
      journal["preferenceBytesUtf8"] = preference_bytes
      journal["preferenceBytesSha256"] = Digest::SHA256.hexdigest(preference_bytes)
      File.binwrite(journal_path, JSON.generate(journal) << "\n")
      reindex_file(root, journal_relative)
      refresh_raw_digest_claims(root, journal_relative)

      error = assert_raises(Support::Error) { Support.verify!(root: root) }
      assert_match(/selected-preference-migrated-v1\.json semantic content differs/, error.message)
      refute_match(/SHA-256 mismatch|canonical result differs/, error.message)
    end
  end

  def test_coherently_rehashed_migration_source_cannot_change_selected_model
    with_temp_corpus do |root|
      source_relative = "bytes/migration-source-manifest-v1.json"
      source_path = File.join(root, source_relative)
      source = JSON.parse(File.binread(source_path))
      changed_model_id = "qwen2.5-1.5b-instruct-q4-k-m"
      source["selectedModelId"] = changed_model_id
      source.fetch("model")["id"] = changed_model_id
      File.binwrite(source_path, JSON.generate(source) << "\n")
      reindex_file(root, source_relative)
      refresh_raw_digest_claims(root, source_relative)
      source_digest = Digest::SHA256.hexdigest(File.binread(source_path))

      journal_relative = "bytes/migration-journal-prepared-v1.json"
      journal_path = File.join(root, journal_relative)
      journal = JSON.parse(File.binread(journal_path))
      journal["sourceManifestSha256"] = source_digest
      File.binwrite(journal_path, JSON.generate(journal) << "\n")
      reindex_file(root, journal_relative)
      refresh_raw_digest_claims(root, journal_relative)

      installation_relative = "installation-v2.json"
      installation_path = File.join(root, installation_relative)
      installation = JSON.parse(File.binread(installation_path))
      adoption = find_case(
        installation,
        "installation/adopt-record-with-migration-intent"
      ).dig("input", "migrationJournal")
      adoption["sourceManifestSha256"] = source_digest
      migration_pair = find_case(
        installation,
        "installation/schema1-pair-migrates"
      ).dig("input", "schema1Pair")
      migration_pair["manifestSha256"] = source_digest
      File.binwrite(installation_path, JSON.pretty_generate(installation) << "\n")
      reindex_file(root, installation_relative)

      error = assert_raises(Support::Error) { Support.verify!(root: root) }
      assert_match(/migration source selected model differs/, error.message)
      refute_match(/SHA-256 mismatch|canonical result differs/, error.message)
    end
  end

  def test_declarative_recovery_quarantine_and_gguf_mutations_fail_after_rehash
    assert_json_mutation_rejected(
      "installation-v2.json",
      /installation\/complete-staging-authorized expected differs/
    ) do |document|
      fixture_case = find_case(document, "installation/complete-staging-authorized")
      fixture_case.fetch("expected")["repair"] = "promote-any-complete-staging"
    end

    assert_json_mutation_rejected(
      "quarantine-v1.json",
      /quarantine reason enum differs/
    ) do |document|
      fixture_case = find_case(document, "quarantine/reason-enum-exhaustive")
      fixture_case.fetch("input").fetch("reasons")[0] = "ARBITRARY_REASON"
    end

    assert_json_mutation_rejected(
      "gguf-v1.json",
      /GGUF error mapping enum differs/
    ) do |document|
      fixture_case = find_case(document, "gguf/error-code-mapping")
      fixture_case.dig("input", "parserGroups", "INTERNAL").delete("PLM_GGUF_BUFFER_TOO_SMALL")
    end

    assert_json_mutation_rejected(
      "gguf-v1.json",
      /GGUF accepted wire versions differs/
    ) do |document|
      fixture_case = find_case(document, "gguf/bad-magic-and-version")
      fixture_case.fetch("input")["acceptedWireVersions"] = [2, 3]
    end
  end

  def test_full_receipt_replay_and_adoption_anchors_reject_rehashed_drift
    assert_json_mutation_rejected("manager-v1.json", /keys must be exactly.*targetQuarantineId/) do |document|
      receipt = find_case(document, "manager/direct-terminal-rejection").fetch("input")
      receipt.delete("targetQuarantineId")
    end

    assert_json_mutation_rejected("manager-v1.json", /direct-terminal-rejection argumentDigest differs/) do |document|
      receipt = find_case(document, "manager/direct-terminal-rejection").fetch("input")
      receipt["argumentDigest"] = "0" * 64
    end

    assert_json_mutation_rejected("manager-v1.json", /prepared < effect < terminal/) do |document|
      receipt = find_case(document, "manager/start-handoff-terminal-timing").dig("input", "receipt")
      receipt["effectManagerRevision"] = "14"
    end

    assert_json_mutation_rejected("manager-v1.json", /retained argumentDigest differs/) do |document|
      retained = find_case(
        document,
        "manager/replay-before-current-revision-check"
      ).dig("input", "retainedTerminalReceipt")
      retained["argumentDigest"] = "0" * 64
    end

    assert_json_mutation_rejected("installation-v2.json", /adoption source manifest digest differs/) do |document|
      adoption = find_case(
        document,
        "installation/adopt-record-with-migration-intent"
      ).dig("input", "migrationJournal")
      adoption["sourceManifestSha256"] = "0" * 64
    end
  end

  private

  def control_command(method)
    {
      "method" => method,
      "modelId" => MODEL_ID,
      "operationId" => OPERATION_ID,
      "expectedRevision" => LARGE_REVISION
    }
  end

  def recommendation_input(models, total_memory)
    {
      "kind" => "recommendation",
      "catalogModels" => models,
      "probeStatus" => "valid",
      "totalMemoryBytes" => total_memory
    }
  end

  def with_temp_corpus
    Dir.mktmpdir("pocketlm-expansion-fixtures-") do |directory|
      root = File.join(directory, "fixture-set-v1")
      FileUtils.cp_r(Support::FIXTURE_SET_ROOT, root)
      yield root
    end
  end

  def assert_json_mutation_rejected(relative, message_pattern)
    with_temp_corpus do |root|
      path = File.join(root, relative)
      document = JSON.parse(File.binread(path))
      yield document
      File.binwrite(path, JSON.generate(document) << "\n")
      reindex_file(root, relative)
      synchronize_catalog_digest(root) if relative == "bytes/catalog-v2-two-models.json"
      refresh_raw_digest_claims(root, relative)

      error = assert_raises(Support::Error) { Support.verify!(root: root) }
      assert_match(message_pattern, error.message)
      refute_match(/SHA-256 mismatch/, error.message)
    end
  end

  def reindex_file(root, relative)
    index_path = File.join(root, Support::INDEX_FILENAME)
    index = JSON.parse(File.binread(index_path))
    entry = index.fetch("files").find { |candidate| candidate.fetch("path") == relative }
    raise "missing index entry for #{relative}" unless entry

    entry["sha256"] = Digest::SHA256.hexdigest(File.binread(File.join(root, relative)))
    File.binwrite(index_path, JSON.pretty_generate(index) << "\n")
  end

  def synchronize_catalog_digest(root)
    relative = "bytes/manager-state-empty-v1.json"
    path = File.join(root, relative)
    state = JSON.parse(File.binread(path))
    state["catalogDigest"] = Digest::SHA256.hexdigest(
      File.binread(File.join(root, "bytes/catalog-v2-two-models.json"))
    )
    File.binwrite(path, JSON.generate(state) << "\n")
    reindex_file(root, relative)
    refresh_raw_digest_claims(root, relative)
  end

  def refresh_raw_digest_claims(root, relative)
    bytes = File.binread(File.join(root, relative))
    replacement = {
      "byteSize" => bytes.bytesize,
      "sha256" => Digest::SHA256.hexdigest(bytes)
    }

    canonical_relative = "canonical-v1.json"
    canonical_path = File.join(root, canonical_relative)
    canonical = JSON.parse(File.binread(canonical_path))
    changed = false
    canonical.fetch("cases").each do |fixture_case|
      next unless fixture_case.dig("input", "kind") == "raw_bytes_digest"
      next unless fixture_case.dig("input", "path") == relative

      fixture_case["expected"] = replacement
      changed = true
    end
    if changed
      File.binwrite(canonical_path, JSON.pretty_generate(canonical) << "\n")
      reindex_file(root, canonical_relative)
    end

    Support::CASE_FILENAMES.each do |case_relative|
      next if case_relative == canonical_relative

      case_path = File.join(root, case_relative)
      document = JSON.parse(File.binread(case_path))
      case_changed = false
      document.fetch("cases").each do |fixture_case|
        next unless fixture_case.dig("input", "bytesFile") == relative
        next unless fixture_case.fetch("expected").key?("sha256")

        fixture_case.fetch("expected")["sha256"] = replacement.fetch("sha256")
        fixture_case.fetch("expected")["byteSize"] = replacement.fetch("byteSize")
        case_changed = true
      end
      next unless case_changed

      File.binwrite(case_path, JSON.pretty_generate(document) << "\n")
      reindex_file(root, case_relative)
    end
  end

  def find_case(document, id)
    document.fetch("cases").find { |fixture_case| fixture_case.fetch("id") == id } ||
      raise("missing fixture case #{id}")
  end
end
