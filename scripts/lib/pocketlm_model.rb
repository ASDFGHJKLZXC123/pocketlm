# frozen_string_literal: true

require "digest"
require "json"
require "set"
require "time"

module PocketLMModel
  class Error < StandardError; end

  module GGUF
    TYPE_UINT8 = 0
    TYPE_INT8 = 1
    TYPE_UINT16 = 2
    TYPE_INT16 = 3
    TYPE_UINT32 = 4
    TYPE_INT32 = 5
    TYPE_FLOAT32 = 6
    TYPE_BOOL = 7
    TYPE_STRING = 8
    TYPE_ARRAY = 9
    TYPE_UINT64 = 10
    TYPE_INT64 = 11
    TYPE_FLOAT64 = 12

    FIXED_TYPE_BYTES = {
      TYPE_UINT8 => 1,
      TYPE_INT8 => 1,
      TYPE_UINT16 => 2,
      TYPE_INT16 => 2,
      TYPE_UINT32 => 4,
      TYPE_INT32 => 4,
      TYPE_FLOAT32 => 4,
      TYPE_BOOL => 1,
      TYPE_UINT64 => 8,
      TYPE_INT64 => 8,
      TYPE_FLOAT64 => 8
    }.freeze

    SCALAR_UNPACK = {
      TYPE_UINT8 => "C",
      TYPE_INT8 => "c",
      TYPE_UINT16 => "S<",
      TYPE_INT16 => "s<",
      TYPE_UINT32 => "L<",
      TYPE_INT32 => "l<",
      TYPE_FLOAT32 => "e",
      TYPE_UINT64 => "Q<",
      TYPE_INT64 => "q<",
      TYPE_FLOAT64 => "E"
    }.freeze

    Header = Struct.new(:magic, :version, :tensor_count, :metadata_count, :metadata,
                        keyword_init: true)

    class Reader
      MAX_TENSOR_COUNT = 10_000_000
      MAX_METADATA_COUNT = 1_000_000
      MAX_ARRAY_ELEMENTS = 5_000_000
      MAX_KEY_BYTES = 1 * 1024 * 1024
      MAX_CAPTURED_STRING_BYTES = 8 * 1024 * 1024

      def initialize(path)
        @path = File.expand_path(path)
      end

      def read(required_keys)
        required = required_keys.to_set
        File.open(@path, "rb") do |io|
          @io = io
          @size = io.stat.size

          magic = read_exact(4, "GGUF magic")
          version = read_uint32("GGUF version")
          tensor_count = read_uint64("tensor count")
          metadata_count = read_uint64("metadata count")

          if tensor_count > MAX_TENSOR_COUNT
            raise Error, "GGUF tensor count is unreasonable: #{tensor_count}"
          end
          if metadata_count > MAX_METADATA_COUNT
            raise Error, "GGUF metadata count is unreasonable: #{metadata_count}"
          end

          metadata = {}
          seen = Set.new
          metadata_count.times do |index|
            key = read_string(capture: true, maximum: MAX_KEY_BYTES,
                              label: "metadata key #{index}")
            raise Error, "duplicate GGUF metadata key: #{key}" unless seen.add?(key)

            type = read_uint32("metadata type for #{key}")
            if required.include?(key)
              metadata[key] = read_captured_value(type, key)
            else
              skip_value(type, "metadata value for #{key}")
            end
          end

          Header.new(
            magic: magic,
            version: version,
            tensor_count: tensor_count,
            metadata_count: metadata_count,
            metadata: metadata
          )
        ensure
          @io = nil
          @size = nil
        end
      rescue Errno::ENOENT
        raise Error, "model file does not exist: #{@path}"
      rescue Errno::EACCES
        raise Error, "model file is not readable: #{@path}"
      end

      private

      def read_captured_value(type, key)
        if type == TYPE_STRING
          return read_string(capture: true, maximum: MAX_CAPTURED_STRING_BYTES,
                             label: "metadata value for #{key}")
        end
        if type == TYPE_BOOL
          value = read_exact(1, "metadata value for #{key}").unpack1("C")
          raise Error, "invalid GGUF boolean for #{key}: #{value}" unless [0, 1].include?(value)

          return value == 1
        end

        format = SCALAR_UNPACK[type]
        width = FIXED_TYPE_BYTES[type]
        unless format && width
          raise Error, "required GGUF metadata #{key} has unsupported type #{type}"
        end

        read_exact(width, "metadata value for #{key}").unpack1(format)
      end

      def skip_value(type, label)
        if (width = FIXED_TYPE_BYTES[type])
          skip_exact(width, label)
        elsif type == TYPE_STRING
          read_string(capture: false, label: label)
        elsif type == TYPE_ARRAY
          element_type = read_uint32("array element type for #{label}")
          count = read_uint64("array length for #{label}")
          skip_array(element_type, count, label)
        else
          raise Error, "unknown GGUF metadata type #{type} for #{label}"
        end
      end

      def skip_array(element_type, count, label)
        if element_type == TYPE_ARRAY
          raise Error, "nested GGUF arrays are not valid for #{label}"
        end
        if count > MAX_ARRAY_ELEMENTS
          raise Error, "GGUF array length is unreasonable for #{label}: #{count}"
        end

        if (width = FIXED_TYPE_BYTES[element_type])
          skip_exact(checked_product(width, count, label), label)
        elsif element_type == TYPE_STRING
          # Every GGUF string has an eight-byte length prefix, including an
          # empty string. Bound the loop by both policy and remaining bytes so
          # an attacker cannot declare a huge iteration count in a tiny file.
          remaining = @size - @io.pos
          if count > remaining / 8
            raise Error, "GGUF string-array length exceeds remaining bytes for #{label}: #{count}"
          end
          count.times do |index|
            read_string(capture: false, label: "#{label}[#{index}]")
          end
        else
          raise Error, "unknown GGUF array element type #{element_type} for #{label}"
        end
      end

      def checked_product(width, count, label)
        remaining = @size - @io.pos
        if count > remaining / width
          raise Error, "truncated GGUF while skipping #{label}"
        end

        width * count
      end

      def read_string(capture:, label:, maximum: nil)
        length = read_uint64("length for #{label}")
        if maximum && length > maximum
          raise Error, "#{label} is too large: #{length} bytes"
        end

        unless capture
          skip_exact(length, label)
          return nil
        end

        bytes = read_exact(length, label)
        value = bytes.force_encoding(Encoding::UTF_8)
        raise Error, "#{label} is not valid UTF-8" unless value.valid_encoding?

        value
      end

      def read_uint32(label)
        read_exact(4, label).unpack1("L<")
      end

      def read_uint64(label)
        read_exact(8, label).unpack1("Q<")
      end

      def read_exact(length, label)
        raise Error, "negative byte count while reading #{label}" if length.negative?
        if length > @size - @io.pos
          raise Error, "truncated GGUF while reading #{label}"
        end

        bytes = @io.read(length)
        unless bytes && bytes.bytesize == length
          raise Error, "truncated GGUF while reading #{label}"
        end

        bytes
      end

      def skip_exact(length, label)
        raise Error, "negative byte count while skipping #{label}" if length.negative?
        if length > @size - @io.pos
          raise Error, "truncated GGUF while skipping #{label}"
        end

        @io.seek(length, IO::SEEK_CUR)
      end
    end
  end

  Catalog = Struct.new(:path, :schema_version, :model, keyword_init: true)

  module_function

  REQUIRED_MODEL_FIELDS = %w[
    id displayName family repository revision artifactIntroducedRevision filename
    sourceUrl byteSize sha256 ggufMagic ggufVersion requiredMetadata quantization
    parameterCountApproximate license licenseUrl gated initialContextTokens
    chatTemplateSource chatTemplateVerified appDirectoryName installedFilename
  ].freeze

  REQUIRED_METADATA_KEYS = %w[
    general.architecture
    general.file_type
    tokenizer.ggml.model
    tokenizer.ggml.pre
    tokenizer.chat_template
  ].freeze

  SAFE_COMPONENT = /\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/
  SHA256 = /\A[0-9a-f]{64}\z/
  REVISION = /\A[0-9a-f]{40}\z/
  QUANTIZATION_FILE_TYPES = { "Q4_K_M" => 15 }.freeze

  def load_catalog(path)
    expanded = File.expand_path(path)
    document = JSON.parse(File.read(expanded))
    raise Error, "catalog root must be an object" unless document.is_a?(Hash)

    schema_version = document["schemaVersion"]
    raise Error, "catalog schemaVersion must be 1" unless schema_version == 1

    models = document["models"]
    unless models.is_a?(Array) && models.length == 1
      raise Error, "PocketLM catalog must contain exactly one model"
    end

    model = models.first
    raise Error, "catalog model must be an object" unless model.is_a?(Hash)

    missing = REQUIRED_MODEL_FIELDS.reject { |field| model.key?(field) }
    raise Error, "catalog model is missing: #{missing.join(', ')}" unless missing.empty?

    validate_catalog_model!(model)
    Catalog.new(path: expanded, schema_version: schema_version, model: model)
  rescue JSON::ParserError => error
    raise Error, "catalog is not valid JSON: #{error.message}"
  rescue Errno::ENOENT
    raise Error, "catalog does not exist: #{expanded}"
  rescue Errno::EACCES
    raise Error, "catalog is not readable: #{expanded}"
  end

  def validate_catalog_model!(model)
    %w[id displayName family repository filename sourceUrl sha256 ggufMagic quantization
       parameterCountApproximate license licenseUrl chatTemplateSource
       appDirectoryName installedFilename].each do |field|
      value = model[field]
      raise Error, "catalog #{field} must be a nonempty string" unless value.is_a?(String) && !value.empty?
    end

    %w[revision artifactIntroducedRevision].each do |field|
      raise Error, "catalog #{field} must be a lowercase 40-character commit" unless REVISION.match?(model[field].to_s)
    end
    raise Error, "catalog sha256 must be lowercase hexadecimal" unless SHA256.match?(model["sha256"])
    unless model["byteSize"].is_a?(Integer) && model["byteSize"] >= 24
      raise Error, "catalog byteSize must be an integer large enough for a GGUF header"
    end
    unless model["ggufVersion"].is_a?(Integer) && model["ggufVersion"].positive?
      raise Error, "catalog ggufVersion must be a positive integer"
    end
    unless model["initialContextTokens"].is_a?(Integer) && model["initialContextTokens"].positive?
      raise Error, "catalog initialContextTokens must be a positive integer"
    end
    raise Error, "catalog ggufMagic must be GGUF" unless model["ggufMagic"] == "GGUF"
    raise Error, "catalog family must be qwen2" unless model["family"] == "qwen2"
    raise Error, "catalog quantization must be Q4_K_M" unless model["quantization"] == "Q4_K_M"
    raise Error, "catalog chatTemplateSource must be gguf_metadata" unless model["chatTemplateSource"] == "gguf_metadata"
    raise Error, "catalog chatTemplateVerified must be true" unless model["chatTemplateVerified"] == true
    raise Error, "catalog gated must be false" unless model["gated"] == false

    %w[id appDirectoryName installedFilename filename].each do |field|
      raise Error, "catalog #{field} is not a safe path component" unless SAFE_COMPONENT.match?(model[field])
    end
    raise Error, "catalog installedFilename must be model.gguf" unless model["installedFilename"] == "model.gguf"

    source_url = model["sourceUrl"]
    expected_source_url = "https://huggingface.co/#{model['repository']}/resolve/" \
                          "#{model['revision']}/#{model['filename']}"
    unless source_url == expected_source_url
      raise Error, "catalog sourceUrl must exactly match repository, revision, and filename"
    end

    requirements = model["requiredMetadata"]
    raise Error, "catalog requiredMetadata must be an object" unless requirements.is_a?(Hash)
    missing = REQUIRED_METADATA_KEYS.reject { |key| requirements.key?(key) }
    raise Error, "catalog requiredMetadata is missing: #{missing.join(', ')}" unless missing.empty?

    architecture = requirements["general.architecture"]
    unless architecture.is_a?(String) && !architecture.empty? && architecture == model["family"]
      raise Error, "catalog general.architecture must match family"
    end
    unless requirements["general.file_type"].is_a?(Integer)
      raise Error, "catalog general.file_type must be an integer"
    end
    expected_file_type = QUANTIZATION_FILE_TYPES[model["quantization"]]
    unless expected_file_type && requirements["general.file_type"] == expected_file_type
      raise Error, "catalog quantization and general.file_type do not match"
    end
    unless requirements["tokenizer.ggml.model"] == "gpt2" &&
           requirements["tokenizer.ggml.pre"] == "qwen2"
      raise Error, "catalog tokenizer metadata must be Qwen2-compatible"
    end

    template = requirements["tokenizer.chat_template"]
    unless template.is_a?(Hash) && template["nonEmpty"] == true
      raise Error, "catalog tokenizer.chat_template must require a nonempty value"
    end
    contains = template["contains"]
    unless contains.is_a?(Array) && !contains.empty? &&
           contains.all? { |value| value.is_a?(String) && !value.empty? }
      raise Error, "catalog tokenizer.chat_template contains must be nonempty strings"
    end
    unless contains.include?("<|im_start|>") && contains.include?("<|im_end|>") &&
           contains.include?("add_generation_prompt")
      raise Error, "catalog tokenizer.chat_template requirements are incomplete"
    end
  end

  def verify_model!(path, catalog)
    model = catalog.model
    expanded = File.expand_path(path)
    stat = File.stat(expanded)
    raise Error, "model path is not a regular file: #{expanded}" unless stat.file?
    unless stat.size == model["byteSize"]
      raise Error, "size mismatch: expected #{model['byteSize']}, got #{stat.size}"
    end

    # Authenticate the complete artifact before interpreting attacker-
    # controlled metadata counts or string lengths.
    actual_sha256 = Digest::SHA256.file(expanded).hexdigest
    unless actual_sha256 == model["sha256"]
      raise Error, "SHA-256 mismatch: expected #{model['sha256']}, got #{actual_sha256}"
    end

    requirements = model["requiredMetadata"]
    header = GGUF::Reader.new(expanded).read(requirements.keys)
    unless header.magic == model["ggufMagic"]
      raise Error, "GGUF magic mismatch: expected #{model['ggufMagic'].inspect}, got #{header.magic.inspect}"
    end
    unless header.version == model["ggufVersion"]
      raise Error, "GGUF version mismatch: expected #{model['ggufVersion']}, got #{header.version}"
    end

    requirements.each do |key, expected|
      raise Error, "required GGUF metadata is missing: #{key}" unless header.metadata.key?(key)

      actual = header.metadata[key]
      if key == "tokenizer.chat_template"
        verify_chat_template!(actual, expected)
      elsif actual != expected
        raise Error, "GGUF metadata mismatch for #{key}: expected #{expected.inspect}, got #{actual.inspect}"
      end
    end

    {
      "path" => expanded,
      "byteSize" => stat.size,
      "sha256" => actual_sha256,
      "ggufMagic" => header.magic,
      "ggufVersion" => header.version,
      "tensorCount" => header.tensor_count,
      "metadataCount" => header.metadata_count,
      "metadata" => header.metadata
    }
  rescue Errno::ENOENT
    raise Error, "model file does not exist: #{expanded}"
  rescue Errno::EACCES
    raise Error, "model file is not readable: #{expanded}"
  end

  def verify_chat_template!(actual, requirement)
    unless actual.is_a?(String)
      raise Error, "GGUF metadata tokenizer.chat_template must be a string"
    end
    if requirement["nonEmpty"] && actual.strip.empty?
      raise Error, "GGUF metadata tokenizer.chat_template is empty"
    end
    requirement.fetch("contains", []).each do |fragment|
      unless actual.include?(fragment)
        raise Error, "GGUF chat template is missing required fragment: #{fragment.inspect}"
      end
    end
  end

  def manifest(catalog, installed_at:, backup_excluded:)
    timestamp = Time.iso8601(installed_at).utc.iso8601
    model = catalog.model
    {
      "schemaVersion" => 1,
      "catalogSchemaVersion" => catalog.schema_version,
      "selectedModelId" => model["id"],
      "installedAt" => timestamp,
      "backupExcluded" => backup_excluded,
      "model" => {
        "id" => model["id"],
        "displayName" => model["displayName"],
        "family" => model["family"],
        "selected" => true,
        "source" => {
          "repository" => model["repository"],
          "revision" => model["revision"],
          "artifactIntroducedRevision" => model["artifactIntroducedRevision"],
          "filename" => model["filename"],
          "url" => model["sourceUrl"]
        },
        "byteSize" => model["byteSize"],
        "sha256" => model["sha256"],
        "ggufMagic" => model["ggufMagic"],
        "ggufVersion" => model["ggufVersion"],
        "requiredMetadata" => model["requiredMetadata"],
        "quantization" => model["quantization"],
        "initialContextTokens" => model["initialContextTokens"],
        "chatTemplateSource" => model["chatTemplateSource"],
        "chatTemplateVerified" => model["chatTemplateVerified"],
        "appDirectoryName" => model["appDirectoryName"],
        "installedFilename" => model["installedFilename"]
      }
    }
  rescue ArgumentError
    raise Error, "installedAt must be an ISO-8601 timestamp"
  end

  def verify_manifest!(path, catalog)
    expanded = File.expand_path(path)
    actual = JSON.parse(File.read(expanded))
    unless actual.is_a?(Hash) && actual["installedAt"].is_a?(String)
      raise Error, "manifest must be an object with installedAt"
    end

    expected = manifest(
      catalog,
      installed_at: actual["installedAt"],
      backup_excluded: true
    )
    raise Error, "manifest does not match the pinned catalog" unless actual == expected

    actual
  rescue JSON::ParserError => error
    raise Error, "manifest is not valid JSON: #{error.message}"
  rescue Errno::ENOENT
    raise Error, "manifest does not exist: #{expanded}"
  rescue Errno::EACCES
    raise Error, "manifest is not readable: #{expanded}"
  end
end
