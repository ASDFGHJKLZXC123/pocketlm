# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/pocketlm_model"
require_relative "fixture_support"

class ModelVerifierTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("pocketlm-model-verifier-", "/tmp")
    @model_path = File.join(@directory, "fixture.gguf")
    @catalog_path = File.join(@directory, "catalog.json")
    PocketLMTestFixture.write_gguf(@model_path)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)
  end

  def teardown
    FileUtils.remove_entry(@directory) if File.exist?(@directory)
  end

  def catalog
    PocketLMModel.load_catalog(@catalog_path)
  end

  def test_verifies_size_hash_header_and_required_metadata
    result = PocketLMModel.verify_model!(@model_path, catalog)

    assert_equal "GGUF", result.fetch("ggufMagic")
    assert_equal 3, result.fetch("ggufVersion")
    assert_equal "qwen2", result.fetch("metadata").fetch("general.architecture")
    assert_equal 15, result.fetch("metadata").fetch("general.file_type")
    assert_includes result.fetch("metadata").fetch("tokenizer.chat_template"), "<|im_start|>"
  end

  def test_rejects_catalog_with_multiple_models
    document = JSON.parse(File.read(@catalog_path))
    document["models"] << document["models"].first.dup
    File.write(@catalog_path, JSON.generate(document))

    error = assert_raises(PocketLMModel::Error) { catalog }
    assert_includes error.message, "exactly one model"
  end

  def test_rejects_unsupported_catalog_schema
    document = JSON.parse(File.read(@catalog_path))
    document["schemaVersion"] = 2
    File.write(@catalog_path, JSON.generate(document))

    error = assert_raises(PocketLMModel::Error) { catalog }
    assert_includes error.message, "schemaVersion must be 1"
  end

  def test_rejects_source_url_that_does_not_match_repository_identity
    document = JSON.parse(File.read(@catalog_path))
    document.fetch("models").first["repository"] = "PocketLM/Other-GGUF"
    File.write(@catalog_path, JSON.generate(document))

    error = assert_raises(PocketLMModel::Error) { catalog }
    assert_includes error.message, "exactly match repository"
  end

  def test_requires_app_catalog_fields
    document = JSON.parse(File.read(@catalog_path))
    document.fetch("models").first.delete("licenseUrl")
    File.write(@catalog_path, JSON.generate(document))

    error = assert_raises(PocketLMModel::Error) { catalog }
    assert_includes error.message, "licenseUrl"
  end

  def test_rejects_corrupt_magic_before_hash
    PocketLMTestFixture.write_gguf(@model_path, magic: "NOPE")
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "GGUF magic mismatch"
  end

  def test_rejects_wrong_gguf_version
    PocketLMTestFixture.write_gguf(@model_path, version: 2)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "GGUF version mismatch"
  end

  def test_rejects_sha256_mismatch
    PocketLMTestFixture.write_catalog(
      @catalog_path,
      @model_path,
      model_overrides: { "sha256" => "0" * 64 }
    )

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "SHA-256 mismatch"
  end

  def test_rejects_hash_before_parsing_corrupt_header
    PocketLMTestFixture.write_gguf(@model_path, magic: "NOPE")
    PocketLMTestFixture.write_catalog(
      @catalog_path,
      @model_path,
      model_overrides: { "sha256" => "0" * 64 }
    )

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "SHA-256 mismatch"
    refute_includes error.message, "GGUF magic"
  end

  def test_rejects_unreasonable_declared_string_array_before_iteration
    write_declared_string_array(5_000_001)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "array length is unreasonable"
  end

  def test_bounds_declared_string_array_by_remaining_file_bytes
    write_declared_string_array(2)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "string-array length exceeds remaining bytes"
  end

  def test_rejects_wrong_architecture_metadata
    metadata = PocketLMTestFixture::DEFAULT_METADATA.merge("general.architecture" => "llama")
    PocketLMTestFixture.write_gguf(@model_path, metadata: metadata)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "general.architecture"
  end

  def test_rejects_missing_tokenizer_metadata
    metadata = PocketLMTestFixture::DEFAULT_METADATA.reject { |key, _| key == "tokenizer.ggml.pre" }
    PocketLMTestFixture.write_gguf(@model_path, metadata: metadata)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "tokenizer.ggml.pre"
  end

  def test_rejects_non_chatml_template
    metadata = PocketLMTestFixture::DEFAULT_METADATA.merge(
      "tokenizer.chat_template" => "{{ message['content'] }}"
    )
    PocketLMTestFixture.write_gguf(@model_path, metadata: metadata)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "required fragment"
  end

  def test_rejects_truncated_metadata
    File.truncate(@model_path, File.size(@model_path) - 2)
    PocketLMTestFixture.write_catalog(@catalog_path, @model_path)

    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_model!(@model_path, catalog)
    end
    assert_includes error.message, "truncated GGUF"
  end

  def test_manifest_round_trip_and_tamper_rejection
    installation = PocketLMModel.manifest(
      catalog,
      installed_at: "2026-07-17T12:34:56Z",
      backup_excluded: true
    )
    manifest_path = File.join(@directory, "manifest.json")
    File.write(manifest_path, JSON.pretty_generate(installation))

    verified = PocketLMModel.verify_manifest!(manifest_path, catalog)
    assert_equal "fixture-q4-k-m", verified.fetch("selectedModelId")
    assert_equal true, verified.fetch("backupExcluded")
    assert_equal true, verified.fetch("model").fetch("selected")
    assert_equal "a" * 40, verified.fetch("model").fetch("source").fetch("revision")

    installation["model"]["sha256"] = "f" * 64
    File.write(manifest_path, JSON.generate(installation))
    error = assert_raises(PocketLMModel::Error) do
      PocketLMModel.verify_manifest!(manifest_path, catalog)
    end
    assert_includes error.message, "does not match"
  end

  private

  def write_declared_string_array(count)
    File.open(@model_path, "wb") do |file|
      file.write("GGUF")
      file.write([3].pack("L<"))
      file.write([0].pack("Q<"))
      file.write([1].pack("Q<"))
      PocketLMTestFixture.write_string(file, "untrusted.array")
      file.write([PocketLMModel::GGUF::TYPE_ARRAY].pack("L<"))
      file.write([PocketLMModel::GGUF::TYPE_STRING].pack("L<"))
      file.write([count].pack("Q<"))
    end
  end
end
