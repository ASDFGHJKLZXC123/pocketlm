# frozen_string_literal: true

require "date"
require "digest"
require "json"
require "pathname"
require "set"

module PocketLMExpansionContractFixtures
  class Error < StandardError; end

  class DuplicateKeyError < StandardError
    attr_reader :key

    def initialize(key)
      @key = key
      super("duplicate object key: #{key.inspect}")
    end
  end

  class StrictJSONObject < Hash
    def []=(key, value)
      raise DuplicateKeyError, key if key?(key)

      super
    end
  end

  FIXTURE_SET_ROOT = File.expand_path(
    "../../fixtures/expansion-gate-0/fixture-set-v1",
    __dir__
  ).freeze
  INDEX_FILENAME = "index.json"
  REQUIRED_ROOT_FILES = %w[
    README.md
    canonical-v1.json
    catalog-v2.json
    installation-v2.json
    preference-v1.json
    manager-v1.json
    paths-v1.json
    leases-v1.json
    gguf-v1.json
    policy-v1.json
    quarantine-v1.json
  ].freeze
  CASE_FILENAMES = (REQUIRED_ROOT_FILES - ["README.md"]).freeze

  MAX_SAFE_INTEGER = 9_007_199_254_740_991
  SAFE_COMPONENT = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  SAFE_FIXTURE_LABEL = /\A[a-z0-9][a-z0-9._:+\/-]*\z/
  DECIMAL_REVISION = /\A(?:0|[1-9][0-9]*)\z/
  LOWERCASE_ID = /\A[0-9a-f]{32}\z/
  LOWERCASE_DIGEST = /\A[0-9a-f]{64}\z/
  TIMESTAMP = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/
  JSON_BOM = "\xEF\xBB\xBF".b.freeze

  SELECTION_ORIGINS = %w[manual recommended migrated fallback].freeze
  PUBLIC_SELECTION_ORIGINS = %w[manual recommended].freeze
  ACCELERATORS = %w[auto cpu metal].freeze
  COMMAND_FIELDS = {
    "startInstall" => %w[modelId expectedRevision],
    "pauseInstall" => %w[modelId operationId expectedRevision],
    "resumeInstall" => %w[modelId operationId expectedRevision],
    "cancelInstall" => %w[modelId operationId expectedRevision],
    "deleteInstallation" => %w[modelId expectedRevision],
    "setSelectedPreference" => %w[modelId origin expectedRevision]
  }.freeze
  PROBE_STATUSES = %w[valid missing malformed].freeze

  MODEL_CONTRACTS = {
    "qwen2.5-0.5b-instruct-q4-k-m" => {
      "id" => "qwen2.5-0.5b-instruct-q4-k-m",
      "displayName" => "Qwen2.5 0.5B Instruct (Q4_K_M)",
      "family" => "qwen2",
      "repository" => "Qwen/Qwen2.5-0.5B-Instruct-GGUF",
      "revision" => "9217f5db79a29953eb74d5343926648285ec7e67",
      "artifactIntroducedRevision" => "6dd44a1fb35d11b5d1b28902876ce3cc9e882d0e",
      "filename" => "qwen2.5-0.5b-instruct-q4_k_m.gguf",
      "sourceUrl" => "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/" \
                     "9217f5db79a29953eb74d5343926648285ec7e67/" \
                     "qwen2.5-0.5b-instruct-q4_k_m.gguf",
      "byteSize" => 491_400_032,
      "sha256" => "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
      "ggufMagic" => "GGUF",
      "ggufVersion" => 3,
      "quantization" => "Q4_K_M",
      "parameterCountApproximate" => "0.49B",
      "license" => "Apache-2.0",
      "licenseUrl" => "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/" \
                      "9217f5db79a29953eb74d5343926648285ec7e67/LICENSE",
      "licenseByteSize" => 11_343,
      "licenseSha256" => "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e",
      "gated" => false,
      "initialContextTokens" => 2_048,
      "minTotalRamBytes" => 2_147_483_648,
      "recommendedRamBytes" => 4_294_967_296,
      "chatTemplateSource" => "gguf_metadata",
      "chatTemplateVerified" => true,
      "appDirectoryName" => "qwen2.5-0.5b-q4km",
      "installedFilename" => "model.gguf",
      "requiredMetadata" => {
        "general.architecture" => "qwen2",
        "general.file_type" => 15,
        "tokenizer.ggml.model" => "gpt2",
        "tokenizer.ggml.pre" => "qwen2",
        "tokenizer.chat_template" => {
          "nonEmpty" => true,
          "byteSize" => 2_509,
          "sha256" => "d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4",
          "contains" => ["<|im_start|>", "<|im_end|>", "add_generation_prompt"]
        }
      }
    },
    "qwen2.5-1.5b-instruct-q4-k-m" => {
      "id" => "qwen2.5-1.5b-instruct-q4-k-m",
      "displayName" => "Qwen2.5 1.5B Instruct (Q4_K_M)",
      "family" => "qwen2",
      "repository" => "Qwen/Qwen2.5-1.5B-Instruct-GGUF",
      "revision" => "91cad51170dc346986eccefdc2dd33a9da36ead9",
      "artifactIntroducedRevision" => "dd26da440ef0330c47919d1ecae0966d24022222",
      "filename" => "qwen2.5-1.5b-instruct-q4_k_m.gguf",
      "sourceUrl" => "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/" \
                     "91cad51170dc346986eccefdc2dd33a9da36ead9/" \
                     "qwen2.5-1.5b-instruct-q4_k_m.gguf",
      "byteSize" => 1_117_320_736,
      "sha256" => "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
      "ggufMagic" => "GGUF",
      "ggufVersion" => 3,
      "quantization" => "Q4_K_M",
      "parameterCountApproximate" => "1.78B",
      "license" => "Apache-2.0",
      "licenseUrl" => "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/" \
                      "91cad51170dc346986eccefdc2dd33a9da36ead9/LICENSE",
      "licenseByteSize" => 11_343,
      "licenseSha256" => "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e",
      "gated" => false,
      "initialContextTokens" => 2_048,
      "minTotalRamBytes" => 4_294_967_296,
      "recommendedRamBytes" => 6_442_450_944,
      "chatTemplateSource" => "gguf_metadata",
      "chatTemplateVerified" => true,
      "appDirectoryName" => "qwen2.5-1.5b-q4km",
      "installedFilename" => "model.gguf",
      "requiredMetadata" => {
        "general.architecture" => "qwen2",
        "general.file_type" => 15,
        "tokenizer.ggml.model" => "gpt2",
        "tokenizer.ggml.pre" => "qwen2",
        "tokenizer.chat_template" => {
          "nonEmpty" => true,
          "byteSize" => 2_509,
          "sha256" => "d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4",
          "contains" => ["<|im_start|>", "<|im_end|>", "add_generation_prompt"]
        }
      }
    }
  }.freeze

  INSTALLATION_CONTRACTS = {
    "qwen2.5-0.5b-instruct-q4-k-m" => {
      "manifestFile" => "bytes/installation-manifest-0.5b-v2.json",
      "commitFile" => "bytes/installation-commit-0.5b-v1.json",
      "publicationId" => "0123456789abcdef0123456789abcdef",
      "installedAt" => "2026-08-23T12:34:56Z",
      "tensorCount" => 291,
      "metadataCount" => 26
    },
    "qwen2.5-1.5b-instruct-q4-k-m" => {
      "manifestFile" => "bytes/installation-manifest-1.5b-v2.json",
      "commitFile" => "bytes/installation-commit-1.5b-v1.json",
      "publicationId" => "fedcba9876543210fedcba9876543210",
      "installedAt" => "2026-08-23T12:35:00Z",
      "tensorCount" => 339,
      "metadataCount" => 26
    }
  }.freeze

  MANAGER_STATE_KEYS = %w[
    schemaVersion revision preferenceRevisionCounter catalogDigest
    transfers commandReceipts quarantines
  ].freeze
  COMMAND_RECEIPT_KEYS = %w[
    schemaVersion commandId method modelId argumentDigest expectedRevision
    targetOperationId createdOperationId targetPublicationId targetQuarantineId
    selectionReleasePlan preferenceMutation phase effectStep preparedManagerRevision
    effectManagerRevision terminalManagerRevision terminalSuccess terminalErrorCode
  ].freeze
  PREFERENCE_DOCUMENT_KEYS = %w[
    schemaVersion revision modelId origin updatedAt
  ].freeze
  MIGRATION_JOURNAL_KEYS = %w[
    schemaVersion sourceManifestSha256 modelId selectedIntent nextPreferenceRevision
    preferenceBytesUtf8 preferenceBytesSha256 phase targetPublicationId installedAt
    targetManifestBytesUtf8 targetManifestSha256 targetMarkerBytesUtf8
    targetMarkerBytesSha256
  ].freeze
  QUARANTINE_SOURCE_KINDS = %w[active staging rollback].freeze
  QUARANTINE_REASONS = %w[
    INVALID_ACTIVE
    UNAUTHORIZED_STAGING
    AMBIGUOUS_STAGING
    INVALID_ROLLBACK
    AMBIGUOUS_ROLLBACK
    PUBLICATION_FAILED
    MISSING_COMMIT_MARKER
    PROTECTION_DRIFT
    BACKUP_EXCLUSION_DRIFT
    MIGRATION_CONFLICT
  ].freeze

  GGUF_ERROR_GROUPS = {
    "GGUF_INVALID" => %w[
      PLM_GGUF_BAD_MAGIC
      PLM_GGUF_UNSUPPORTED_VERSION
      PLM_GGUF_TRUNCATED
      PLM_GGUF_CORRUPT
      PLM_GGUF_DUPLICATE_KEY
      PLM_GGUF_MISSING_FIELD
      PLM_GGUF_WRONG_TYPE
      PLM_GGUF_INVALID_UTF8
    ],
    "GGUF_BOUNDS" => %w[
      PLM_GGUF_COUNT_LIMIT
      PLM_GGUF_OVERFLOW
      PLM_GGUF_FIELD_TOO_LARGE
    ],
    "STORAGE_IO" => %w[PLM_GGUF_IO],
    "PATH_REJECTED" => %w[PLM_GGUF_NOT_REGULAR],
    "INTERNAL" => %w[
      PLM_GGUF_INVALID_ARGUMENT
      PLM_GGUF_BUFFER_TOO_SMALL
      PLM_GGUF_INTERNAL
    ]
  }.freeze

  module_function

  def canonical_timestamp?(value)
    return false unless value.is_a?(String)

    match = TIMESTAMP.match(value)
    return false unless match

    year, month, day, hour, minute, second = match.captures.map(&:to_i)
    year.positive? &&
      Date.valid_date?(year, month, day, Date::GREGORIAN) &&
      hour.between?(0, 23) &&
      minute.between?(0, 59) &&
      second.between?(0, 59)
  end

  def canonical_decimal_revision?(value)
    value.is_a?(String) && DECIMAL_REVISION.match?(value)
  end

  def compare_decimal_revisions(left, right)
    require_decimal_revision!(left, "left revision")
    require_decimal_revision!(right, "right revision")

    length_order = left.length <=> right.length
    return length_order unless length_order.zero?

    left <=> right
  end

  def increment_decimal_revision(value)
    require_decimal_revision!(value, "revision")

    digits = value.bytes
    cursor = digits.length - 1
    while cursor >= 0 && digits[cursor] == 57
      digits[cursor] = 48
      cursor -= 1
    end
    if cursor.negative?
      digits.unshift(49)
    else
      digits[cursor] += 1
    end
    digits.pack("C*")
  end

  def canonical_lowercase_id?(value)
    value.is_a?(String) && LOWERCASE_ID.match?(value) && value != ("0" * 32)
  end

  def canonical_lowercase_digest?(value)
    value.is_a?(String) && LOWERCASE_DIGEST.match?(value)
  end

  def strict_json_parse(bytes, label: "JSON")
    raise Error, "#{label} bytes must be a String" unless bytes.is_a?(String)

    raw = bytes.dup.b
    raise Error, "#{label} has a UTF-8 BOM" if raw.start_with?(JSON_BOM)

    text = raw.force_encoding(Encoding::UTF_8)
    raise Error, "#{label} is not valid UTF-8" unless text.valid_encoding?

    JSON.parse(text, object_class: StrictJSONObject, create_additions: false)
  rescue DuplicateKeyError => error
    raise Error, "#{label} contains a duplicate object key: #{error.key.inspect}"
  rescue JSON::ParserError => error
    raise Error, "#{label} is not valid JSON: #{error.message}"
  end

  def runtime_fingerprint(fields)
    require_hash!(fields, "runtime fingerprint fields")
    require_exact_keys!(
      fields,
      %w[
        modelId artifactSha256 publicationId contextSize
        requestedAccelerator gpuLayers policyProfileVersion
      ],
      "runtime fingerprint fields"
    )

    model_id = require_model_id!(fields.fetch("modelId"))
    artifact_sha256 = fields.fetch("artifactSha256")
    unless canonical_lowercase_digest?(artifact_sha256)
      raise Error, "runtime fingerprint artifactSha256 must be lowercase 64-hex"
    end
    publication_id = fields.fetch("publicationId")
    unless canonical_lowercase_id?(publication_id)
      raise Error, "runtime fingerprint publicationId must be nonzero lowercase 32-hex"
    end

    context_size = require_safe_integer!(
      fields.fetch("contextSize"),
      "runtime fingerprint contextSize",
      minimum: 1
    )
    accelerator = fields.fetch("requestedAccelerator")
    unless ACCELERATORS.include?(accelerator)
      raise Error, "runtime fingerprint requestedAccelerator is invalid"
    end
    gpu_layers = require_safe_integer!(
      fields.fetch("gpuLayers"),
      "runtime fingerprint gpuLayers",
      minimum: 0
    )
    policy_version = require_safe_integer!(
      fields.fetch("policyProfileVersion"),
      "runtime fingerprint policyProfileVersion",
      minimum: 1
    )

    digest_nul_fields(
      "PocketLM/runtime-fingerprint/v1",
      model_id,
      artifact_sha256,
      publication_id,
      context_size.to_s,
      accelerator,
      gpu_layers.to_s,
      policy_version.to_s
    )
  end

  def command_argument_digest(input)
    require_hash!(input, "command digest input")
    method = input["method"]
    fields = COMMAND_FIELDS[method]
    raise Error, "command digest method is invalid" unless fields

    require_exact_keys!(input, ["method", *fields], "command digest input")
    normalized = [method]
    fields.each do |field|
      value = input.fetch(field)
      case field
      when "modelId"
        value = require_model_id!(value)
      when "operationId"
        unless canonical_lowercase_id?(value)
          raise Error, "command digest operationId must be nonzero lowercase 32-hex"
        end
      when "expectedRevision"
        require_decimal_revision!(value, "command digest expectedRevision")
      when "origin"
        unless PUBLIC_SELECTION_ORIGINS.include?(value)
          raise Error, "command digest public origin must be manual or recommended"
        end
      end
      normalized << value
    end

    digest_nul_fields("PocketLM/model-manager-command/v1", *normalized)
  end

  def policy_recommendation(input)
    require_hash!(input, "policy recommendation input")
    require_exact_keys!(
      input,
      %w[kind catalogModels probeStatus totalMemoryBytes],
      "policy recommendation input"
    )
    raise Error, "policy recommendation kind is invalid" unless input.fetch("kind") == "recommendation"

    probe_status = input.fetch("probeStatus")
    raise Error, "policy probeStatus is invalid" unless PROBE_STATUSES.include?(probe_status)
    total_memory = require_safe_integer!(
      input.fetch("totalMemoryBytes"),
      "policy totalMemoryBytes",
      minimum: 0
    )
    models = input.fetch("catalogModels")
    unless models.is_a?(Array) && !models.empty?
      raise Error, "policy catalogModels must be a nonempty array"
    end

    seen = Set.new
    validated = models.map.with_index do |model, index|
      require_hash!(model, "policy catalog model #{index}")
      require_exact_keys!(
        model,
        %w[id minTotalRamBytes recommendedRamBytes],
        "policy catalog model #{index}"
      )
      model_id = require_model_id!(model.fetch("id"))
      raise Error, "policy catalog model ID is duplicated: #{model_id}" unless seen.add?(model_id)

      minimum = require_safe_integer!(
        model.fetch("minTotalRamBytes"),
        "policy minTotalRamBytes",
        minimum: 1
      )
      recommended = require_safe_integer!(
        model.fetch("recommendedRamBytes"),
        "policy recommendedRamBytes",
        minimum: 1
      )
      raise Error, "policy RAM thresholds are inverted for #{model_id}" if minimum > recommended

      [model_id, minimum, recommended]
    end

    return { "modelId" => nil, "claimDeviceFit" => false } unless probe_status == "valid"

    selected = validated.reverse.find { |_id, _minimum, recommended| recommended <= total_memory }
    selected ||= validated.find { |_id, minimum, _recommended| minimum <= total_memory }
    {
      "modelId" => selected&.first,
      "claimDeviceFit" => !selected.nil?
    }
  end

  def policy_n_threads(input)
    require_hash!(input, "n_threads policy input")
    kind = input["kind"]
    raise Error, "n_threads policy kind is invalid" unless kind == "n_threads"
    probe_status = input["probeStatus"]
    raise Error, "policy probeStatus is invalid" unless PROBE_STATUSES.include?(probe_status)
    return { "value" => 0 } unless probe_status == "valid"

    platform = input["platform"]
    active_count = require_safe_integer!(
      input.fetch("activeProcessorCount"),
      "policy activeProcessorCount",
      minimum: 1
    )
    if platform == "ios"
      require_exact_keys!(
        input,
        %w[kind probeStatus platform activeProcessorCount],
        "iOS n_threads policy input"
      )
      return { "value" => [active_count, 4].min }
    end
    raise Error, "n_threads policy platform is invalid" unless platform == "android"

    require_exact_keys!(
      input,
      %w[kind probeStatus platform activeProcessorCount maxFrequencyKhzByCpu],
      "Android n_threads policy input"
    )
    frequencies = input.fetch("maxFrequencyKhzByCpu")
    unless frequencies.is_a?(Array) && !frequencies.empty? && active_count <= frequencies.length
      raise Error, "Android frequency vector must cover every active processor"
    end
    frequencies.each_with_index do |frequency, index|
      next if frequency.nil?

      require_safe_integer!(frequency, "Android CPU frequency #{index}", minimum: 0)
    end
    if frequencies.any?(&:nil?)
      return { "value" => [active_count, 4].min }
    end

    maximum = frequencies.max
    performance_count = frequencies.count { |frequency| (10 * frequency) >= (9 * maximum) }
    upper_bound = [active_count, 4].min
    { "value" => [[performance_count, 1].max, upper_bound].min }
  end

  def verify!(root: FIXTURE_SET_ROOT)
    CorpusVerifier.new(root).verify!
  end

  def digest_nul_fields(prefix, *fields)
    values = [prefix, *fields]
    values.each_with_index do |value, index|
      unless value.is_a?(String) && value.valid_encoding? && !value.include?("\0")
        raise Error, "digest field #{index} must be valid UTF-8 without NUL"
      end
    end
    Digest::SHA256.hexdigest(values.join("\0").encode(Encoding::UTF_8))
  end

  def require_decimal_revision!(value, label)
    return value if canonical_decimal_revision?(value)

    raise Error, "#{label} must be a canonical decimal revision"
  end
  private_class_method :require_decimal_revision!

  def require_hash!(value, label)
    return value if value.is_a?(Hash)

    raise Error, "#{label} must be an object"
  end
  private_class_method :require_hash!

  def require_exact_keys!(value, expected, label)
    actual = value.keys.sort
    wanted = expected.sort
    return if actual == wanted

    raise Error, "#{label} keys must be exactly #{wanted.join(', ')}; got #{actual.join(', ')}"
  end
  private_class_method :require_exact_keys!

  def require_model_id!(value)
    unless value.is_a?(String) && SAFE_COMPONENT.match?(value) && !%w[. ..].include?(value)
      raise Error, "modelId must be a safe nonempty component"
    end
    value
  end
  private_class_method :require_model_id!

  def require_safe_integer!(value, label, minimum:)
    unless value.is_a?(Integer) && value.between?(minimum, MAX_SAFE_INTEGER)
      raise Error, "#{label} must be a safe integer at least #{minimum}"
    end
    value
  end
  private_class_method :require_safe_integer!

  class CorpusVerifier
    def initialize(root)
      @root = File.expand_path(root)
      @documents = {}
      @parsed_json = {}
    end

    def verify!
      ensure_root!
      index = read_json(INDEX_FILENAME)
      validate_index!(index)
      validate_case_files!(index)
      validate_canonical_vectors!
      validate_policy_vectors!
      validate_catalog_anchors!
      validate_installation_anchors!
      validate_preference_anchors!
      validate_manager_anchors!
      validate_recovery_anchors!
      validate_quarantine_anchors!
      validate_gguf_anchors!
      {
        "fixtureSet" => index.fetch("fixtureSet"),
        "fileCount" => indexed_files(index).length,
        "caseCount" => @documents.values.sum { |document| document.fetch("cases").length },
        "families" => @documents.values.map { |document| document.fetch("family") }.sort
      }
    end

    private

    def ensure_root!
      stat = File.lstat(@root)
      raise Error, "fixture root must be a directory" unless stat.directory?
      raise Error, "fixture root must not be a symlink" if stat.symlink?
    rescue Errno::ENOENT
      raise Error, "fixture root does not exist: #{@root}"
    end

    def validate_index!(index)
      require_object!(index, INDEX_FILENAME)
      fixture_set = index["fixtureSet"]
      unless valid_label?(fixture_set)
        raise Error, "index fixtureSet must be a lowercase fixture label"
      end

      files = indexed_files(index)
      paths = files.map do |entry|
        require_exact_object_keys!(entry, %w[path sha256], "index file entry")
        path = entry.fetch("path")
        validate_relative_path!(path)
        digest = entry.fetch("sha256")
        unless PocketLMExpansionContractFixtures.canonical_lowercase_digest?(digest)
          raise Error, "index digest for #{path.inspect} must be lowercase 64-hex"
        end
        path
      end
      require_sorted_unique!(paths, "index file paths")

      actual_paths = discover_files - [INDEX_FILENAME]
      unless paths == actual_paths
        raise Error,
              "index inventory differs from disk; indexed=#{paths.inspect}, actual=#{actual_paths.inspect}"
      end
      missing_required = REQUIRED_ROOT_FILES - paths
      unless missing_required.empty?
        raise Error, "index is missing required files: #{missing_required.join(', ')}"
      end
      unexpected_root = paths.reject do |path|
        REQUIRED_ROOT_FILES.include?(path) || path.start_with?("bytes/")
      end
      unless unexpected_root.empty?
        raise Error, "files must be required root files or bytes sidecars: #{unexpected_root.join(', ')}"
      end

      files.each do |entry|
        path = entry.fetch("path")
        bytes = read_bytes(path)
        validate_utf8!(bytes, path)
        actual = Digest::SHA256.hexdigest(bytes)
        expected = entry.fetch("sha256")
        raise Error, "SHA-256 mismatch for #{path}" unless actual == expected

        read_json(path) if File.extname(path) == ".json"
      end

      coverage = index["requiredCoverage"]
      require_object!(coverage, "index requiredCoverage")
      raise Error, "index requiredCoverage must not be empty" if coverage.empty?
      coverage.each do |family, tags|
        raise Error, "requiredCoverage family is invalid: #{family.inspect}" unless valid_label?(family)
        validate_string_list!(tags, "requiredCoverage #{family}", allow_empty: false)
      end
    end

    def validate_case_files!(index)
      fixture_set = index.fetch("fixtureSet")
      families = {}
      global_ids = Set.new

      CASE_FILENAMES.each do |filename|
        document = read_json(filename)
        require_exact_object_keys!(document, %w[fixtureSet family cases], filename)
        unless document.fetch("fixtureSet") == fixture_set
          raise Error, "#{filename} fixtureSet does not match index"
        end

        family = document.fetch("family")
        raise Error, "#{filename} family is invalid" unless valid_label?(family)
        if families.key?(family)
          raise Error, "fixture family #{family.inspect} appears in more than one file"
        end
        families[family] = filename

        cases = document.fetch("cases")
        unless cases.is_a?(Array) && !cases.empty?
          raise Error, "#{filename} cases must be a nonempty array"
        end
        ids = cases.map do |fixture_case|
          validate_case!(fixture_case, filename)
          id = fixture_case.fetch("id")
          raise Error, "fixture case ID is globally duplicated: #{id}" unless global_ids.add?(id)
          id
        end
        require_sorted_unique!(ids, "#{filename} case IDs")
        @documents[filename] = document
      end

      required_coverage = index.fetch("requiredCoverage")
      unless required_coverage.keys.to_set == families.keys.to_set
        raise Error,
              "requiredCoverage families differ from case families; " \
              "required=#{required_coverage.keys.sort.inspect}, actual=#{families.keys.sort.inspect}"
      end

      @documents.each do |filename, document|
        family = document.fetch("family")
        actual = document.fetch("cases").flat_map { |fixture_case| fixture_case.fetch("coverage") }.uniq.sort
        expected = required_coverage.fetch(family)
        unless actual == expected
          raise Error,
                "#{filename} coverage differs from index; expected=#{expected.inspect}, actual=#{actual.inspect}"
        end
      end
    end

    def validate_case!(fixture_case, filename)
      require_exact_object_keys!(
        fixture_case,
        %w[id accepted coverage input expected],
        "#{filename} case"
      )
      id = fixture_case.fetch("id")
      raise Error, "#{filename} case ID is invalid: #{id.inspect}" unless valid_label?(id)
      unless [true, false].include?(fixture_case.fetch("accepted"))
        raise Error, "#{id} accepted must be boolean"
      end
      validate_string_list!(fixture_case.fetch("coverage"), "#{id} coverage", allow_empty: false)
      require_object!(fixture_case.fetch("input"), "#{id} input")
      require_object!(fixture_case.fetch("expected"), "#{id} expected")
    end

    def validate_canonical_vectors!
      document = @documents.fetch("canonical-v1.json")
      document.fetch("cases").each do |fixture_case|
        input = fixture_case.fetch("input")
        expected = fixture_case.fetch("expected")
        actual = evaluate_canonical_case(input)
        unless actual == expected
          raise Error,
                "#{fixture_case.fetch('id')} canonical result differs; " \
                "expected=#{expected.inspect}, actual=#{actual.inspect}"
        end

        kind = input.fetch("kind")
        if %w[timestamp decimal_revision lowercase_id lowercase_digest].include?(kind)
          unless fixture_case.fetch("accepted") == actual.fetch("canonical")
            raise Error, "#{fixture_case.fetch('id')} accepted disagrees with canonical result"
          end
        elsif fixture_case.fetch("accepted") != true
          raise Error, "#{fixture_case.fetch('id')} must be accepted when it yields a value"
        end
      rescue KeyError => error
        raise Error, "#{fixture_case.fetch('id')} canonical vector is missing #{error.key}"
      end
    end

    def evaluate_canonical_case(input)
      kind = input.fetch("kind")
      case kind
      when "timestamp"
        require_exact_object_keys!(input, %w[kind value], "timestamp input")
        { "canonical" => PocketLMExpansionContractFixtures.canonical_timestamp?(input.fetch("value")) }
      when "decimal_revision"
        require_exact_object_keys!(input, %w[kind value], "decimal revision input")
        { "canonical" => PocketLMExpansionContractFixtures.canonical_decimal_revision?(input.fetch("value")) }
      when "revision_compare"
        require_exact_object_keys!(input, %w[kind left right], "revision comparison input")
        {
          "result" => PocketLMExpansionContractFixtures.compare_decimal_revisions(
            input.fetch("left"), input.fetch("right")
          )
        }
      when "revision_increment"
        require_exact_object_keys!(input, %w[kind value], "revision increment input")
        { "value" => PocketLMExpansionContractFixtures.increment_decimal_revision(input.fetch("value")) }
      when "lowercase_id"
        require_exact_object_keys!(input, %w[kind value], "lowercase ID input")
        { "canonical" => PocketLMExpansionContractFixtures.canonical_lowercase_id?(input.fetch("value")) }
      when "lowercase_digest"
        require_exact_object_keys!(input, %w[kind value], "lowercase digest input")
        { "canonical" => PocketLMExpansionContractFixtures.canonical_lowercase_digest?(input.fetch("value")) }
      when "runtime_fingerprint"
        require_exact_object_keys!(input, %w[kind fields], "runtime fingerprint input")
        { "sha256" => PocketLMExpansionContractFixtures.runtime_fingerprint(input.fetch("fields")) }
      when "command_digest"
        command = input.reject { |key, _value| key == "kind" }
        { "sha256" => PocketLMExpansionContractFixtures.command_argument_digest(command) }
      when "raw_bytes_digest"
        require_exact_object_keys!(input, %w[kind path], "raw bytes digest input")
        path = input.fetch("path")
        validate_relative_path!(path)
        bytes = read_bytes(path)
        { "byteSize" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes) }
      else
        raise Error, "unknown canonical vector kind: #{kind.inspect}"
      end
    end

    def validate_policy_vectors!
      document = @documents.fetch("policy-v1.json")
      declarative_kinds = %w[manual_selection probe_invariants runtime_config simulator_advisory]
      document.fetch("cases").each do |fixture_case|
        input = fixture_case.fetch("input")
        kind = input.fetch("kind")
        actual = case kind
                 when "recommendation"
                   PocketLMExpansionContractFixtures.policy_recommendation(input)
                 when "n_threads"
                   PocketLMExpansionContractFixtures.policy_n_threads(input)
                 else
                   next if declarative_kinds.include?(kind)

                   raise Error, "unknown policy vector kind: #{kind.inspect}"
                 end
        expected = fixture_case.fetch("expected")
        unless actual == expected
          raise Error,
                "#{fixture_case.fetch('id')} policy result differs; " \
                "expected=#{expected.inspect}, actual=#{actual.inspect}"
        end
        raise Error, "#{fixture_case.fetch('id')} executable policy vector must be accepted" unless fixture_case.fetch("accepted")
      rescue KeyError => error
        raise Error, "#{fixture_case.fetch('id')} policy vector is missing #{error.key}"
      end
    end

    def validate_catalog_anchors!
      expected_models_by_file = {
        "bytes/catalog-v2-one-model.json" => [
          MODEL_CONTRACTS.fetch("qwen2.5-0.5b-instruct-q4-k-m")
        ],
        "bytes/catalog-v2-two-models.json" => MODEL_CONTRACTS.values
      }

      expected_models_by_file.each do |path, expected_models|
        catalog = read_json(path)
        require_exact_object_keys!(catalog, %w[schemaVersion models], path)
        raise Error, "#{path} schemaVersion must be 2" unless catalog.fetch("schemaVersion") == 2
        unless catalog.fetch("models") == expected_models
          raise Error, "#{path} differs from the frozen model identity, policy, or template facts"
        end

        catalog.fetch("models").each_with_index do |model, index|
          expected_model = expected_models.fetch(index)
          require_exact_object_keys!(model, expected_model.keys, "#{path} model #{index}")
          required_metadata = model.fetch("requiredMetadata")
          require_exact_object_keys!(
            required_metadata,
            expected_model.fetch("requiredMetadata").keys,
            "#{path} model #{index} requiredMetadata"
          )
          require_exact_object_keys!(
            required_metadata.fetch("tokenizer.chat_template"),
            %w[nonEmpty byteSize sha256 contains],
            "#{path} model #{index} chat-template predicate"
          )
        end
      end

      {
        "catalog/valid-one-model" => [
          "bytes/catalog-v2-one-model.json",
          ["qwen2.5-0.5b-instruct-q4-k-m"]
        ],
        "catalog/valid-two-models" => [
          "bytes/catalog-v2-two-models.json",
          MODEL_CONTRACTS.keys
        ]
      }.each do |id, (path, model_ids)|
        fixture_case = require_case_anchor!(
          "catalog-v2.json",
          id,
          accepted: true,
          expected: { "result" => "accepted", "modelIds" => model_ids }
        )
        expected_input = { "bytesFile" => path, "schema" => "CatalogV2" }
        require_equal!(fixture_case.fetch("input"), expected_input, "#{id} input")
      end

      pinned = require_case_anchor!(
        "catalog-v2.json",
        "catalog/pinned-byte-and-ram-values",
        accepted: true,
        expected: {
          "models" => MODEL_CONTRACTS.values.map do |model|
            {
              "id" => model.fetch("id"),
              "artifactBytes" => model.fetch("byteSize"),
              "licenseBytes" => model.fetch("licenseByteSize"),
              "templateBytes" => model.dig("requiredMetadata", "tokenizer.chat_template", "byteSize"),
              "minTotalRamBytes" => model.fetch("minTotalRamBytes"),
              "recommendedRamBytes" => model.fetch("recommendedRamBytes")
            }
          end
        }
      )
      require_equal!(
        pinned.fetch("input"),
        { "bytesFile" => "bytes/catalog-v2-two-models.json" },
        "catalog/pinned-byte-and-ram-values input"
      )

      require_case_anchor!(
        "catalog-v2.json",
        "catalog/exact-template-equality",
        accepted: true,
        expected: {
          "templateByteSizeBoth" => 2_509,
          "templateSha256Both" =>
            "d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4",
          "equalityUsesExactBytes" => true
        }
      )
    end

    def validate_installation_anchors!
      INSTALLATION_CONTRACTS.each do |model_id, installation|
        model = MODEL_CONTRACTS.fetch(model_id)
        manifest_path = installation.fetch("manifestFile")
        marker_path = installation.fetch("commitFile")
        manifest = read_json(manifest_path)
        marker = read_json(marker_path)

        require_exact_object_keys!(
          manifest,
          %w[
            schemaVersion catalogSchemaVersion modelId publicationId installedAt
            backupExcluded relativePath artifact inspection
          ],
          manifest_path
        )
        require_exact_object_keys!(
          manifest.fetch("relativePath"),
          %w[appDirectoryName installedFilename],
          "#{manifest_path} relativePath"
        )
        require_exact_object_keys!(
          manifest.fetch("artifact"),
          %w[byteSize sha256 sourceRevision sourceFilename],
          "#{manifest_path} artifact"
        )
        require_exact_object_keys!(
          manifest.fetch("inspection"),
          %w[
            inspectorFactsVersion ggufVersion tensorCount metadataCount architecture
            fileType tokenizerModel tokenizerPre chatTemplateSha256 chatTemplateBytes
          ],
          "#{manifest_path} inspection"
        )
        require_exact_object_keys!(
          marker,
          %w[schemaVersion publicationId manifestSha256 modelSha256 modelByteSize],
          marker_path
        )

        expected_manifest = {
          "schemaVersion" => 2,
          "catalogSchemaVersion" => 2,
          "modelId" => model_id,
          "publicationId" => installation.fetch("publicationId"),
          "installedAt" => installation.fetch("installedAt"),
          "backupExcluded" => true,
          "relativePath" => {
            "appDirectoryName" => model.fetch("appDirectoryName"),
            "installedFilename" => model.fetch("installedFilename")
          },
          "artifact" => {
            "byteSize" => model.fetch("byteSize"),
            "sha256" => model.fetch("sha256"),
            "sourceRevision" => model.fetch("revision"),
            "sourceFilename" => model.fetch("filename")
          },
          "inspection" => {
            "inspectorFactsVersion" => 1,
            "ggufVersion" => model.fetch("ggufVersion"),
            "tensorCount" => installation.fetch("tensorCount"),
            "metadataCount" => installation.fetch("metadataCount"),
            "architecture" => model.dig("requiredMetadata", "general.architecture"),
            "fileType" => model.dig("requiredMetadata", "general.file_type"),
            "tokenizerModel" => model.dig("requiredMetadata", "tokenizer.ggml.model"),
            "tokenizerPre" => model.dig("requiredMetadata", "tokenizer.ggml.pre"),
            "chatTemplateSha256" =>
              model.dig("requiredMetadata", "tokenizer.chat_template", "sha256"),
            "chatTemplateBytes" =>
              model.dig("requiredMetadata", "tokenizer.chat_template", "byteSize")
          }
        }
        require_equal!(manifest, expected_manifest, "#{manifest_path} semantic content")

        expected_marker = {
          "schemaVersion" => 1,
          "publicationId" => manifest.fetch("publicationId"),
          "manifestSha256" => Digest::SHA256.hexdigest(read_bytes(manifest_path)),
          "modelSha256" => manifest.dig("artifact", "sha256"),
          "modelByteSize" => manifest.dig("artifact", "byteSize")
        }
        require_equal!(marker, expected_marker, "#{marker_path} manifest/model agreement")

        short_size = model.fetch("parameterCountApproximate").start_with?("0.49") ? "0.5b" : "1.5b"
        fixture_case = require_case_anchor!(
          "installation-v2.json",
          "installation/valid-v2-#{short_size}",
          accepted: true,
          expected: {
            "result" => "loadable",
            "publicationId" => installation.fetch("publicationId")
          }
        )
        require_equal!(
          fixture_case.fetch("input"),
          {
            "manifestFile" => manifest_path,
            "commitFile" => marker_path,
            "model" => {
              "byteSize" => model.fetch("byteSize"),
              "sha256" => model.fetch("sha256"),
              "regularFile" => true
            },
            "protection" => { "backupExcluded" => true, "permissions" => "verified" }
          },
          "#{fixture_case.fetch('id')} input"
        )
      end
    end

    def validate_preference_anchors!
      all_origins = require_case_anchor!(
        "preference-v1.json",
        "preference/all-origins",
        accepted: true,
        expected: { "result" => "accepted", "durableOrigins" => SELECTION_ORIGINS }
      )
      origins = all_origins.fetch("input").fetch("documents").map { |document| document.fetch("origin") }
      require_equal!(origins, SELECTION_ORIGINS, "preference/all-origins durable origin order")

      authority = require_case_anchor!(
        "preference-v1.json",
        "preference/public-origin-authority",
        accepted: true,
        expected: {
          "manual" => "accepted",
          "recommended" => "accepted",
          "migrated" => "INVALID_ARGUMENT",
          "fallback" => "INVALID_ARGUMENT"
        }
      )
      require_equal!(
        authority.fetch("input"),
        {
          "method" => "setSelectedPreference",
          "publicAcceptedOrigins" => PUBLIC_SELECTION_ORIGINS,
          "internalOnlyOrigins" => SELECTION_ORIGINS - PUBLIC_SELECTION_ORIGINS
        },
        "preference/public-origin-authority input"
      )

      validate_preference_sidecar_anchors!
      validate_migration_source_manifest_anchor!
      validate_migration_journal_anchor!
    end

    def validate_preference_sidecar_anchors!
      {
        "bytes/selected-preference-manual-v1.json" => "manual",
        "bytes/selected-preference-migrated-v1.json" => "migrated"
      }.each do |path, origin|
        document = read_json(path)
        require_exact_object_keys!(document, PREFERENCE_DOCUMENT_KEYS, path)
        require_equal!(
          document,
          {
            "schemaVersion" => 1,
            "revision" => "1",
            "modelId" => "qwen2.5-0.5b-instruct-q4-k-m",
            "origin" => origin,
            "updatedAt" => "2026-08-23T12:34:56Z"
          },
          "#{path} semantic content"
        )
        unless PocketLMExpansionContractFixtures.canonical_timestamp?(document.fetch("updatedAt"))
          raise Error, "#{path} updatedAt must be an exact canonical timestamp"
        end
      end
    end

    def validate_migration_source_manifest_anchor!
      path = "bytes/migration-source-manifest-v1.json"
      document = read_json(path)
      require_exact_object_keys!(
        document,
        %w[
          schemaVersion catalogSchemaVersion selectedModelId installedAt
          backupExcluded model
        ],
        path
      )
      model = document.fetch("model")
      require_exact_object_keys!(
        model,
        %w[
          id displayName family selected source byteSize sha256 ggufMagic ggufVersion
          requiredMetadata quantization initialContextTokens chatTemplateSource
          chatTemplateVerified appDirectoryName installedFilename
        ],
        "#{path} model"
      )
      require_exact_object_keys!(
        model.fetch("source"),
        %w[repository revision artifactIntroducedRevision filename url],
        "#{path} model source"
      )
      require_exact_object_keys!(
        model.fetch("requiredMetadata"),
        %w[
          general.architecture general.file_type tokenizer.ggml.model
          tokenizer.ggml.pre tokenizer.chat_template
        ],
        "#{path} requiredMetadata"
      )
      require_exact_object_keys!(
        model.dig("requiredMetadata", "tokenizer.chat_template"),
        %w[nonEmpty contains],
        "#{path} chat-template predicate"
      )

      frozen_model = MODEL_CONTRACTS.fetch("qwen2.5-0.5b-instruct-q4-k-m")
      require_equal!(
        document.fetch("selectedModelId"),
        model.fetch("id"),
        "migration source selected identity agreement"
      )
      require_equal!(
        document.fetch("selectedModelId"),
        frozen_model.fetch("id"),
        "migration source selected model"
      )
      require_equal!(model.fetch("selected"), true, "migration source selected intent")
      unless PocketLMExpansionContractFixtures.canonical_timestamp?(document.fetch("installedAt"))
        raise Error, "#{path} installedAt must be an exact canonical timestamp"
      end

      expected = {
        "schemaVersion" => 1,
        "catalogSchemaVersion" => 1,
        "selectedModelId" => frozen_model.fetch("id"),
        "installedAt" => "2026-08-23T12:34:56Z",
        "backupExcluded" => true,
        "model" => {
          "id" => frozen_model.fetch("id"),
          "displayName" => frozen_model.fetch("displayName"),
          "family" => frozen_model.fetch("family"),
          "selected" => true,
          "source" => {
            "repository" => frozen_model.fetch("repository"),
            "revision" => frozen_model.fetch("revision"),
            "artifactIntroducedRevision" => frozen_model.fetch("artifactIntroducedRevision"),
            "filename" => frozen_model.fetch("filename"),
            "url" => frozen_model.fetch("sourceUrl")
          },
          "byteSize" => frozen_model.fetch("byteSize"),
          "sha256" => frozen_model.fetch("sha256"),
          "ggufMagic" => frozen_model.fetch("ggufMagic"),
          "ggufVersion" => frozen_model.fetch("ggufVersion"),
          "requiredMetadata" => {
            "general.architecture" => frozen_model.dig("requiredMetadata", "general.architecture"),
            "general.file_type" => frozen_model.dig("requiredMetadata", "general.file_type"),
            "tokenizer.ggml.model" => frozen_model.dig("requiredMetadata", "tokenizer.ggml.model"),
            "tokenizer.ggml.pre" => frozen_model.dig("requiredMetadata", "tokenizer.ggml.pre"),
            "tokenizer.chat_template" => {
              "nonEmpty" => true,
              "contains" => frozen_model.dig(
                "requiredMetadata",
                "tokenizer.chat_template",
                "contains"
              )
            }
          },
          "quantization" => frozen_model.fetch("quantization"),
          "initialContextTokens" => frozen_model.fetch("initialContextTokens"),
          "chatTemplateSource" => frozen_model.fetch("chatTemplateSource"),
          "chatTemplateVerified" => frozen_model.fetch("chatTemplateVerified"),
          "appDirectoryName" => frozen_model.fetch("appDirectoryName"),
          "installedFilename" => frozen_model.fetch("installedFilename")
        }
      }
      require_equal!(document, expected, "#{path} semantic content")
    end

    def validate_migration_journal_anchor!
      path = "bytes/migration-journal-prepared-v1.json"
      bytes = read_bytes(path)
      raise Error, "#{path} exceeds the 1 MiB contract cap" if bytes.bytesize > 1_048_576

      journal = read_json(path)
      require_exact_object_keys!(journal, MIGRATION_JOURNAL_KEYS, path)
      require_equal!(journal.fetch("schemaVersion"), 1, "#{path} schemaVersion")
      require_equal!(journal.fetch("modelId"), MODEL_CONTRACTS.keys.first, "#{path} modelId")
      require_equal!(journal.fetch("selectedIntent"), "selected", "#{path} selectedIntent")
      require_equal!(journal.fetch("nextPreferenceRevision"), "1", "#{path} nextPreferenceRevision")
      require_equal!(journal.fetch("phase"), "prepared", "#{path} phase")
      require_equal!(
        journal.fetch("targetPublicationId"),
        INSTALLATION_CONTRACTS.fetch(MODEL_CONTRACTS.keys.first).fetch("publicationId"),
        "#{path} targetPublicationId"
      )
      require_equal!(journal.fetch("installedAt"), "2026-08-23T12:34:56Z", "#{path} installedAt")

      source_bytes = read_bytes("bytes/migration-source-manifest-v1.json")
      require_equal!(
        journal.fetch("sourceManifestSha256"),
        Digest::SHA256.hexdigest(source_bytes),
        "#{path} source manifest digest"
      )

      nested_files = {
        "preferenceBytesUtf8" => [
          "preferenceBytesSha256",
          "bytes/selected-preference-migrated-v1.json"
        ],
        "targetManifestBytesUtf8" => [
          "targetManifestSha256",
          "bytes/installation-manifest-0.5b-v2.json"
        ],
        "targetMarkerBytesUtf8" => [
          "targetMarkerBytesSha256",
          "bytes/installation-commit-0.5b-v1.json"
        ]
      }
      nested_files.each do |bytes_field, (digest_field, nested_path)|
        nested_bytes = journal.fetch(bytes_field).b
        require_equal!(nested_bytes, read_bytes(nested_path), "#{path} #{bytes_field} raw bytes")
        require_equal!(
          journal.fetch(digest_field),
          Digest::SHA256.hexdigest(nested_bytes),
          "#{path} #{digest_field}"
        )
        require_equal!(
          PocketLMExpansionContractFixtures.strict_json_parse(
            nested_bytes,
            label: "#{path} #{bytes_field}"
          ),
          read_json(nested_path),
          "#{path} #{bytes_field} parsed value"
        )
      end

      fixture_case = require_case_anchor!(
        "preference-v1.json",
        "preference/migration-journal-valid-prepared",
        accepted: true,
        expected: {
          "byteSize" => bytes.bytesize,
          "sha256" => Digest::SHA256.hexdigest(bytes),
          "nestedByteDigestsMatch" => true,
          "phase" => "prepared"
        }
      )
      require_equal!(
        fixture_case.fetch("input"),
        { "bytesFile" => path, "schema" => "MigrationJournalV1" },
        "preference/migration-journal-valid-prepared input"
      )
    end

    def validate_manager_anchors!
      path = "bytes/manager-state-empty-v1.json"
      bytes = read_bytes(path)
      raise Error, "#{path} exceeds the 4 MiB contract cap" if bytes.bytesize > 4_194_304

      state = read_json(path)
      require_exact_object_keys!(state, MANAGER_STATE_KEYS, path)
      require_equal!(state.fetch("schemaVersion"), 1, "#{path} schemaVersion")
      require_equal!(state.fetch("revision"), "0", "#{path} revision")
      require_equal!(
        state.fetch("preferenceRevisionCounter"),
        "0",
        "#{path} preferenceRevisionCounter"
      )
      require_equal!(
        state.fetch("catalogDigest"),
        Digest::SHA256.hexdigest(read_bytes("bytes/catalog-v2-two-models.json")),
        "#{path} catalogDigest"
      )
      %w[transfers commandReceipts quarantines].each do |field|
        require_equal!(state.fetch(field), [], "#{path} #{field}")
      end

      fixture_case = require_case_anchor!(
        "manager-v1.json",
        "manager/manager-state-size-and-closed-schema",
        accepted: true,
        expected: {
          "validFile" => "accepted",
          "oversize" => "STORAGE_IO",
          "unknownField" => "rejected",
          "platformOpaqueDataShared" => false
        }
      )
      input = fixture_case.fetch("input")
      require_equal!(input.fetch("validBytesFile"), path, "#{fixture_case.fetch('id')} validBytesFile")
      require_equal!(input.fetch("maxBytes"), 4_194_304, "#{fixture_case.fetch('id')} maxBytes")
      require_equal!(input.fetch("rejectAtBytes"), 4_194_305, "#{fixture_case.fetch('id')} rejectAtBytes")
      unknown = input.fetch("unknownFieldDocument")
      require_exact_object_keys!(
        unknown,
        MANAGER_STATE_KEYS + ["nativeResumeBlob"],
        "#{fixture_case.fetch('id')} unknown-field document"
      )

      validate_manager_receipt_anchors!
    end

    def validate_manager_receipt_anchors!
      model_id = "qwen2.5-0.5b-instruct-q4-k-m"
      direct_case = require_case_anchor!(
        "manager-v1.json",
        "manager/direct-terminal-rejection",
        accepted: true,
        expected: {
          "result" => "accepted-receipt",
          "durablyReplayError" => "STALE_REVISION",
          "managerRevision" => "10"
        }
      )
      direct_receipt = direct_case.fetch("input")
      validate_full_command_receipt!(direct_receipt, direct_case.fetch("id"))
      require_equal!(
        direct_receipt,
        {
          "schemaVersion" => 1,
          "commandId" => "22222222222222222222222222222222",
          "method" => "deleteInstallation",
          "modelId" => model_id,
          "argumentDigest" =>
            "42c88d87512c0a6a56c3fe3e1d37f93d0ea4609d3b376c18cc30ec3e09b6a9f8",
          "expectedRevision" => "8",
          "targetOperationId" => nil,
          "createdOperationId" => nil,
          "targetPublicationId" => nil,
          "targetQuarantineId" => nil,
          "selectionReleasePlan" => nil,
          "preferenceMutation" => nil,
          "phase" => "terminal",
          "effectStep" => nil,
          "preparedManagerRevision" => "10",
          "effectManagerRevision" => nil,
          "terminalManagerRevision" => "10",
          "terminalSuccess" => false,
          "terminalErrorCode" => "STALE_REVISION"
        },
        "#{direct_case.fetch('id')} full receipt"
      )

      handoff_case = require_case_anchor!(
        "manager-v1.json",
        "manager/start-handoff-terminal-timing",
        accepted: true,
        expected: {
          "promise" => "fulfilled",
          "operationIdDurable" => true,
          "waitsForPublication" => false
        }
      )
      handoff_input = handoff_case.fetch("input")
      require_exact_object_keys!(
        handoff_input,
        %w[receipt transferState publicationComplete],
        "#{handoff_case.fetch('id')} input"
      )
      require_equal!(handoff_input.fetch("transferState"), "queued", "handoff transferState")
      require_equal!(handoff_input.fetch("publicationComplete"), false, "handoff publicationComplete")
      handoff_receipt = handoff_input.fetch("receipt")
      validate_full_command_receipt!(handoff_receipt, handoff_case.fetch("id"))
      require_equal!(
        handoff_receipt,
        {
          "schemaVersion" => 1,
          "commandId" => "22222222222222222222222222222222",
          "method" => "startInstall",
          "modelId" => model_id,
          "argumentDigest" =>
            "339ff663f43cde365305bbb12b70d176bea8287ad6028c58cd72e616893b589c",
          "expectedRevision" => "10",
          "targetOperationId" => nil,
          "createdOperationId" => "11111111111111111111111111111111",
          "targetPublicationId" => nil,
          "targetQuarantineId" => nil,
          "selectionReleasePlan" => nil,
          "preferenceMutation" => nil,
          "phase" => "terminal",
          "effectStep" => "platformOperationStarted",
          "preparedManagerRevision" => "11",
          "effectManagerRevision" => "12",
          "terminalManagerRevision" => "13",
          "terminalSuccess" => true,
          "terminalErrorCode" => nil
        },
        "#{handoff_case.fetch('id')} full receipt"
      )

      replay_case = require_case_anchor!(
        "manager-v1.json",
        "manager/replay-before-current-revision-check",
        accepted: true,
        expected: {
          "result" => "replay-stored-success",
          "currentRevisionChecked" => false,
          "newReceiptCreated" => false
        }
      )
      replay_input = replay_case.fetch("input")
      require_exact_object_keys!(
        replay_input,
        %w[retainedTerminalReceipt replay currentManagerRevision],
        "#{replay_case.fetch('id')} input"
      )
      retained = replay_input.fetch("retainedTerminalReceipt")
      require_exact_object_keys!(
        retained,
        %w[commandId argumentDigest expectedRevision terminalSuccess terminalManagerRevision],
        "#{replay_case.fetch('id')} retained receipt"
      )
      %w[commandId argumentDigest expectedRevision terminalSuccess terminalManagerRevision].each do |field|
        require_equal!(
          retained.fetch(field),
          handoff_receipt.fetch(field),
          "#{replay_case.fetch('id')} retained #{field}"
        )
      end
      require_equal!(
        replay_input.fetch("replay"),
        { "sameCommandId" => true, "sameArgumentDigest" => true },
        "#{replay_case.fetch('id')} replay identity"
      )
      current_revision = replay_input.fetch("currentManagerRevision")
      unless PocketLMExpansionContractFixtures.compare_decimal_revisions(
        current_revision,
        retained.fetch("terminalManagerRevision")
      ).positive?
        raise Error, "#{replay_case.fetch('id')} current revision must be newer than retained receipt"
      end
    end

    def validate_full_command_receipt!(receipt, label)
      require_exact_object_keys!(receipt, COMMAND_RECEIPT_KEYS, "#{label} receipt")
      require_equal!(receipt.fetch("schemaVersion"), 1, "#{label} receipt schemaVersion")
      unless PocketLMExpansionContractFixtures.canonical_lowercase_id?(receipt.fetch("commandId"))
        raise Error, "#{label} receipt commandId must be nonzero lowercase 32-hex"
      end

      digest_input = {
        "method" => receipt.fetch("method"),
        "modelId" => receipt.fetch("modelId"),
        "expectedRevision" => receipt.fetch("expectedRevision")
      }
      expected_digest = PocketLMExpansionContractFixtures.command_argument_digest(digest_input)
      require_equal!(receipt.fetch("argumentDigest"), expected_digest, "#{label} argumentDigest")

      revision_fields = %w[
        expectedRevision preparedManagerRevision terminalManagerRevision
      ]
      revision_fields.each do |field|
        unless PocketLMExpansionContractFixtures.canonical_decimal_revision?(receipt.fetch(field))
          raise Error, "#{label} #{field} must be a canonical decimal revision"
        end
      end
      expected_revision = receipt.fetch("expectedRevision")
      prepared_revision = receipt.fetch("preparedManagerRevision")
      terminal_revision = receipt.fetch("terminalManagerRevision")
      unless PocketLMExpansionContractFixtures.compare_decimal_revisions(
        expected_revision,
        prepared_revision
      ).negative?
        raise Error, "#{label} receipt revision order must place expected before prepared"
      end

      effect_revision = receipt.fetch("effectManagerRevision")
      if effect_revision.nil?
        require_equal!(
          terminal_revision,
          prepared_revision,
          "#{label} direct-terminal revision order"
        )
      else
        unless PocketLMExpansionContractFixtures.canonical_decimal_revision?(effect_revision) &&
               PocketLMExpansionContractFixtures.compare_decimal_revisions(
                 prepared_revision,
                 effect_revision
               ).negative? &&
               PocketLMExpansionContractFixtures.compare_decimal_revisions(
                 effect_revision,
                 terminal_revision
               ).negative?
          raise Error, "#{label} receipt revision order must be prepared < effect < terminal"
        end
      end

      require_equal!(receipt.fetch("phase"), "terminal", "#{label} receipt phase")
      if receipt.fetch("terminalSuccess")
        require_equal!(receipt.fetch("terminalErrorCode"), nil, "#{label} terminal success error")
      elsif receipt.fetch("terminalErrorCode").nil?
        raise Error, "#{label} terminal failure must carry an error code"
      end
    end

    def validate_recovery_anchors!
      expected_cases = {
        "installation/active-invalid-no-rollback" => [
          false,
          { "repair" => "quarantine-active", "installState" => "invalid", "loadPath" => nil }
        ],
        "installation/invalid-only-rollback" => [
          false,
          { "repair" => "quarantine-rollback", "installState" => "invalid", "loadPath" => nil }
        ],
        "installation/complete-staging-authorized" => [
          true,
          {
            "repair" => "promote-authorized-staging",
            "installState" => "committed",
            "publicationId" => "0123456789abcdef0123456789abcdef"
          }
        ],
        "installation/complete-staging-unauthorized" => [
          false,
          { "repair" => "quarantine-staging", "installState" => "invalid", "loadPath" => nil }
        ],
        "installation/multiple-staging-ambiguous" => [
          false,
          {
            "repair" => "quarantine-ambiguous-staging",
            "installState" => "invalid",
            "promotedOperationId" => nil
          }
        ],
        "installation/multiple-rollbacks-ambiguous" => [
          false,
          { "repair" => "fail-closed", "errorCode" => "STORAGE_IO", "managerReady" => false }
        ],
        "installation/record-without-marker-ordinary-load" => [
          false,
          { "repair" => "quarantine-stray-record", "installState" => "invalid", "loadable" => false }
        ],
        "installation/adopt-record-with-migration-intent" => [
          true,
          {
            "repair" => "reinspect-and-write-matching-marker",
            "installState" => "committed",
            "publicationId" => "0123456789abcdef0123456789abcdef"
          }
        ]
      }
      cases = expected_cases.each_with_object({}) do |(id, (accepted, expected)), result|
        result[id] = require_case_anchor!(
          "installation-v2.json",
          id,
          accepted: accepted,
          expected: expected
        )
      end

      active_invalid = cases.fetch("installation/active-invalid-no-rollback").fetch("input")
      require_equal!(active_invalid.fetch("rollbacks"), [], "active-invalid recovery rollbacks")
      require_equal!(active_invalid.fetch("active").fetch("modelIdentity"), "hash-mismatch", "active-invalid identity")

      invalid_rollback = cases.fetch("installation/invalid-only-rollback").fetch("input")
      require_equal!(invalid_rollback.fetch("active"), nil, "invalid-only rollback active")
      require_equal!(invalid_rollback.fetch("rollbacks").length, 1, "invalid-only rollback count")
      require_equal!(invalid_rollback.dig("rollbacks", 0, "valid"), false, "invalid-only rollback validity")

      authorized = cases.fetch("installation/complete-staging-authorized").fetch("input")
      require_equal!(authorized.fetch("staging").length, 1, "authorized staging count")
      require_equal!(
        authorized.dig("persistedTransfer", "operationId"),
        authorized.dig("staging", 0, "operationId"),
        "authorized staging operation authority"
      )

      unauthorized = cases.fetch("installation/complete-staging-unauthorized").fetch("input")
      require_equal!(unauthorized.fetch("staging").length, 1, "unauthorized staging count")
      require_equal!(unauthorized.fetch("persistedTransfer"), nil, "unauthorized staging authority")

      multiple_staging = cases.fetch("installation/multiple-staging-ambiguous").fetch("input")
      staging_ids = multiple_staging.fetch("staging").map { |entry| entry.fetch("operationId") }
      require_equal!(staging_ids.length, 2, "ambiguous staging count")
      if staging_ids.include?(multiple_staging.dig("persistedTransfer", "operationId"))
        raise Error, "ambiguous staging fixture must not authorize either candidate"
      end

      multiple_rollbacks = cases.fetch("installation/multiple-rollbacks-ambiguous").fetch("input")
      require_equal!(multiple_rollbacks.fetch("rollbacks").length, 2, "ambiguous rollback count")

      stray = cases.fetch("installation/record-without-marker-ordinary-load").fetch("input")
      require_equal!(stray.dig("active", "commitFile"), nil, "stray record commit marker")
      require_equal!(stray.fetch("migrationJournal"), nil, "stray record migration authority")
      require_equal!(stray.fetch("persistedTransfer"), nil, "stray record transfer authority")

      adoption = cases.fetch("installation/adopt-record-with-migration-intent").fetch("input")
      require_equal!(adoption.dig("active", "commitFile"), nil, "adoptable record commit marker")
      require_equal!(adoption.dig("migrationJournal", "phase"), "recordWritten", "adoption journal phase")
      require_equal!(
        adoption.dig("migrationJournal", "sourceManifestSha256"),
        Digest::SHA256.hexdigest(read_bytes("bytes/migration-source-manifest-v1.json")),
        "adoption source manifest digest"
      )
      require_equal!(
        adoption.dig("migrationJournal", "targetPublicationId"),
        "0123456789abcdef0123456789abcdef",
        "adoption publication authority"
      )
    end

    def validate_quarantine_anchors!
      closed = require_case_anchor!(
        "quarantine-v1.json",
        "quarantine/closed-valid-record",
        accepted: true,
        expected: { "result" => "accepted", "loadable" => false, "managerStateIndexMustMatch" => true }
      )
      record = closed.fetch("input")
      quarantine_keys = %w[
        schemaVersion quarantineId modelId publicationId sourceKind reason
        createdManagerRevision quarantinedAt byteSize
      ]
      require_exact_object_keys!(record, quarantine_keys, "quarantine/closed-valid-record input")
      require_equal!(record.fetch("schemaVersion"), 1, "quarantine schemaVersion")
      unless PocketLMExpansionContractFixtures.canonical_lowercase_id?(record.fetch("quarantineId"))
        raise Error, "quarantineId must be nonzero lowercase 32-hex"
      end
      unless PocketLMExpansionContractFixtures.canonical_lowercase_id?(record.fetch("publicationId"))
        raise Error, "quarantine publicationId must be nonzero lowercase 32-hex when present"
      end
      unless QUARANTINE_SOURCE_KINDS.include?(record.fetch("sourceKind"))
        raise Error, "quarantine sourceKind is outside the frozen enum"
      end
      unless QUARANTINE_REASONS.include?(record.fetch("reason"))
        raise Error, "quarantine reason is outside the frozen enum"
      end
      unless PocketLMExpansionContractFixtures.canonical_decimal_revision?(
        record.fetch("createdManagerRevision")
      )
        raise Error, "quarantine createdManagerRevision is not canonical"
      end
      unless PocketLMExpansionContractFixtures.canonical_timestamp?(record.fetch("quarantinedAt"))
        raise Error, "quarantine quarantinedAt is not canonical"
      end

      reasons = require_case_anchor!(
        "quarantine-v1.json",
        "quarantine/reason-enum-exhaustive",
        accepted: true,
        expected: {
          "stableOrder" => true,
          "unknownReasonRejected" => true,
          "diagnosticTextControlsFlow" => false
        }
      )
      require_equal!(reasons.dig("input", "reasons"), QUARANTINE_REASONS, "quarantine reason enum")

      unknown = require_case_anchor!(
        "quarantine-v1.json",
        "quarantine/unknown-field-rejected",
        accepted: false,
        expected: { "result" => "rejected", "reason" => "closed-schema-unknown-field" }
      )
      require_exact_object_keys!(
        unknown.fetch("input"),
        quarantine_keys + ["deleteAfterDays"],
        "quarantine/unknown-field-rejected input"
      )

      ui = require_case_anchor!(
        "quarantine-v1.json",
        "quarantine/not-loadable-and-ui-recovery",
        accepted: true,
        expected: {
          "installState" => "invalid",
          "resolveLoadPath" => "PATH_REJECTED",
          "actions" => ["Retry install", "Delete damaged files"]
        }
      )
      require_equal!(ui.dig("input", "activeGeneration"), nil, "quarantine UI active generation")

      newest = require_case_anchor!(
        "quarantine-v1.json",
        "quarantine/newest-manager-revision-retained",
        accepted: true,
        expected: {
          "retainedQuarantineId" => "33333333333333333333333333333333",
          "deleteOlderBeforeRepairComplete" => false,
          "deleteOlderAfterRepairComplete" => true
        }
      )
      newest_record = newest.dig("input", "records").max do |left, right|
        PocketLMExpansionContractFixtures.compare_decimal_revisions(
          left.fetch("createdManagerRevision"),
          right.fetch("createdManagerRevision")
        )
      end
      require_equal!(
        newest_record.fetch("quarantineId"),
        newest.dig("expected", "retainedQuarantineId"),
        "quarantine newest-retention computation"
      )

      disk = case_by_id("quarantine-v1.json", "quarantine/disk-preflight-includes-retained-bytes")
      disk_input = disk.fetch("input")
      required_bytes = disk_input.values_at(
        "candidateBytes", "retainedQuarantineBytes", "otherRequiredBytes"
      ).sum
      require_equal!(required_bytes, disk.dig("expected", "requiredBytes"), "quarantine disk preflight sum")
      require_equal!(
        disk_input.fetch("freeDiskBytes") >= required_bytes,
        disk.dig("expected", "sufficient"),
        "quarantine disk preflight sufficiency"
      )

      require_case_anchor!(
        "quarantine-v1.json",
        "quarantine/no-age-based-deletion",
        accepted: true,
        expected: { "retain" => true, "timestampOrdersState" => false }
      )
    end

    def validate_gguf_anchors!
      gguf_facts = {
        "gguf/valid-0.5b-facts" => {
          "artifact" => {
            "byteSize" => 491_400_032,
            "sha256" => "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
          },
          "gguf" => {
            "version" => 3,
            "tensorCount" => 291,
            "metadataCount" => 26,
            "architecture" => "qwen2",
            "fileType" => 15,
            "tokenizerModel" => "gpt2",
            "tokenizerPre" => "qwen2",
            "chatTemplateBytes" => 2_509,
            "chatTemplateSha256" =>
              "d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4"
          },
          "backendSessionConstructionCountBefore" => 0
        },
        "gguf/valid-1.5b-facts" => {
          "artifact" => {
            "byteSize" => 1_117_320_736,
            "sha256" => "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"
          },
          "gguf" => {
            "version" => 3,
            "tensorCount" => 339,
            "metadataCount" => 26,
            "parameterCount" => 1_777_088_000,
            "alignment" => 32,
            "dataOffset" => 5_950_496,
            "architecture" => "qwen2",
            "fileType" => 15,
            "tokenizerModel" => "gpt2",
            "tokenizerPre" => "qwen2",
            "chatTemplateBytes" => 2_509,
            "chatTemplateSha256" =>
              "d5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4"
          }
        }
      }
      gguf_facts.each do |id, input|
        expected = { "parserResult" => "PLM_GGUF_OK", "platformComparison" => "match" }
        expected["backendSessionConstructionCountAfter"] = 0 if id.include?("0.5b")
        fixture_case = require_case_anchor!("gguf-v1.json", id, accepted: true, expected: expected)
        require_equal!(fixture_case.fetch("input"), input, "#{id} input")
      end

      mapping = require_case_anchor!(
        "gguf-v1.json",
        "gguf/error-code-mapping",
        accepted: true,
        expected: { "mappingIsExhaustive" => true, "diagnosticTextControlsFlow" => false }
      )
      require_equal!(mapping.dig("input", "parserGroups"), GGUF_ERROR_GROUPS, "GGUF error mapping enum")
      require_equal!(mapping.dig("input", "catalogComparison"), "METADATA_MISMATCH", "GGUF catalog mapping")

      count_limits = require_case_anchor!(
        "gguf-v1.json",
        "gguf/count-limits-and-overflow",
        accepted: true,
        expected: {
          "capPlusOneResult" => "PLM_GGUF_COUNT_LIMIT",
          "overflowResult" => "PLM_GGUF_OVERFLOW",
          "managerErrorCode" => "GGUF_BOUNDS"
        }
      )
      require_equal!(
        count_limits.dig("input", "boundaries"),
        [
          { "field" => "tensorCount", "accepted" => 10_000_000, "rejected" => 10_000_001 },
          { "field" => "metadataCount", "accepted" => 65_536, "rejected" => 65_537 },
          { "field" => "arrayElementCount", "accepted" => 5_000_000, "rejected" => 5_000_001 }
        ],
        "GGUF count limits"
      )

      field_caps = require_case_anchor!(
        "gguf-v1.json",
        "gguf/exact-field-caps",
        accepted: true,
        expected: {
          "capResult" => "PLM_GGUF_OK",
          "capPlusOneResult" => "PLM_GGUF_FIELD_TOO_LARGE",
          "maximumTemplateAllocation" => 1_048_577
        }
      )
      require_equal!(
        field_caps.dig("input", "boundaries"),
        [
          { "field" => "metadataKeyBytes", "accepted" => 65_536, "rejected" => 65_537 },
          { "field" => "architectureBytes", "accepted" => 63, "rejected" => 64 },
          { "field" => "tokenizerModelBytes", "accepted" => 63, "rejected" => 64 },
          { "field" => "tokenizerPreBytes", "accepted" => 63, "rejected" => 64 },
          { "field" => "chatTemplateBytes", "accepted" => 1_048_576, "rejected" => 1_048_577 }
        ],
        "GGUF field caps"
      )

      require_case_anchor!(
        "gguf-v1.json",
        "gguf/sizing-request",
        accepted: true,
        expected: {
          "parserResult" => "PLM_GGUF_OK",
          "trustedFactsReturned" => true,
          "chatTemplateLength" => 2_509,
          "requiredChatTemplateCapacity" => 2_510,
          "templateBytesWritten" => 0
        }
      )
      require_case_anchor!(
        "gguf-v1.json",
        "gguf/buffer-too-small",
        accepted: false,
        expected: {
          "parserResult" => "PLM_GGUF_BUFFER_TOO_SMALL",
          "requiredChatTemplateCapacity" => 2_510,
          "partialTemplateBytes" => 0,
          "trustedFactsReturned" => false,
          "otherOutputsZeroed" => true
        }
      )
      require_case_anchor!(
        "gguf-v1.json",
        "gguf/empty-template-parses-but-mismatches",
        accepted: false,
        expected: {
          "parserResult" => "PLM_GGUF_OK",
          "chatTemplateLength" => 0,
          "requiredChatTemplateCapacity" => 1,
          "platformComparison" => "METADATA_MISMATCH"
        }
      )
      bad_version = require_case_anchor!(
        "gguf-v1.json",
        "gguf/bad-magic-and-version",
        accepted: false,
        expected: {
          "parserResults" => [
            "PLM_GGUF_BAD_MAGIC",
            "PLM_GGUF_UNSUPPORTED_VERSION",
            "PLM_GGUF_UNSUPPORTED_VERSION",
            "PLM_GGUF_UNSUPPORTED_VERSION"
          ],
          "managerErrorCode" => "GGUF_INVALID",
          "metadataInterpretedForUnsupportedVersion" => false,
          "factsZeroed" => true
        }
      )
      bad_version_input = bad_version.fetch("input")
      require_exact_object_keys!(
        bad_version_input,
        %w[acceptedWireVersions variants],
        "gguf/bad-magic-and-version input"
      )
      require_equal!(
        bad_version_input.fetch("acceptedWireVersions"),
        [3],
        "GGUF accepted wire versions"
      )
      require_equal!(
        bad_version_input.fetch("variants"),
        [
          { "magicAscii" => "GGUX", "version" => 3 },
          { "magicAscii" => "GGUF", "version" => 1 },
          { "magicAscii" => "GGUF", "version" => 2 },
          { "magicAscii" => "GGUF", "version" => 4 }
        ],
        "GGUF rejected magic/version matrix"
      )
    end

    def case_by_id(filename, id)
      document = @documents.fetch(filename)
      fixture_case = document.fetch("cases").find { |candidate| candidate.fetch("id") == id }
      raise Error, "#{filename} is missing required semantic anchor #{id}" unless fixture_case

      fixture_case
    end

    def require_case_anchor!(filename, id, accepted:, expected:)
      fixture_case = case_by_id(filename, id)
      require_equal!(fixture_case.fetch("accepted"), accepted, "#{id} accepted")
      require_equal!(fixture_case.fetch("expected"), expected, "#{id} expected")
      fixture_case
    end

    def require_equal!(actual, expected, label)
      return if actual == expected

      raise Error, "#{label} differs; expected=#{expected.inspect}, actual=#{actual.inspect}"
    end

    def indexed_files(index)
      files = index["files"]
      raise Error, "index files must be an array" unless files.is_a?(Array)

      files
    end

    def discover_files
      entries = Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).sort
      files = []
      entries.each do |entry|
        basename = File.basename(entry)
        next if %w[. ..].include?(basename)

        stat = File.lstat(entry)
        raise Error, "fixture corpus must not contain symlinks: #{entry}" if stat.symlink?
        next if stat.directory?
        raise Error, "fixture corpus entry must be a regular file: #{entry}" unless stat.file?

        relative = Pathname.new(entry).relative_path_from(Pathname.new(@root)).to_s
        validate_relative_path!(relative)
        files << relative
      end
      files.sort
    end

    def read_json(relative)
      return @parsed_json.fetch(relative) if @parsed_json.key?(relative)

      bytes = read_bytes(relative)
      @parsed_json[relative] = PocketLMExpansionContractFixtures.strict_json_parse(
        bytes,
        label: relative
      )
    end

    def read_bytes(relative)
      validate_relative_path!(relative)
      path = File.join(@root, relative)
      stat = File.lstat(path)
      raise Error, "fixture file must not be a symlink: #{relative}" if stat.symlink?
      raise Error, "fixture path must be a regular file: #{relative}" unless stat.file?
      File.binread(path)
    rescue Errno::ENOENT
      raise Error, "fixture file does not exist: #{relative}"
    end

    def validate_utf8!(bytes, relative)
      raise Error, "fixture file has a UTF-8 BOM: #{relative}" if bytes.start_with?(JSON_BOM)

      text = bytes.dup.force_encoding(Encoding::UTF_8)
      raise Error, "fixture file is not valid UTF-8: #{relative}" unless text.valid_encoding?
    end

    def validate_relative_path!(relative)
      unless relative.is_a?(String) && !relative.empty? && relative.ascii_only? && !relative.include?("\\")
        raise Error, "fixture path must be a nonempty portable ASCII relative path: #{relative.inspect}"
      end
      path = Pathname.new(relative)
      if path.absolute? || path.cleanpath.to_s != relative
        raise Error, "fixture path is not canonical and relative: #{relative.inspect}"
      end
      components = relative.split("/", -1)
      unless components.all? { |component| SAFE_COMPONENT.match?(component) && !%w[. ..].include?(component) }
        raise Error, "fixture path contains an unsafe component: #{relative.inspect}"
      end
    end

    def require_object!(value, label)
      raise Error, "#{label} must be an object" unless value.is_a?(Hash)
    end

    def require_exact_object_keys!(value, expected, label)
      require_object!(value, label)
      actual = value.keys.sort
      wanted = expected.sort
      return if actual == wanted

      raise Error, "#{label} keys must be exactly #{wanted.join(', ')}; got #{actual.join(', ')}"
    end

    def validate_string_list!(value, label, allow_empty:)
      unless value.is_a?(Array) && (allow_empty || !value.empty?) &&
             value.all? { |item| valid_label?(item) }
        raise Error, "#{label} must be #{allow_empty ? 'a' : 'a nonempty'} list of fixture labels"
      end
      require_sorted_unique!(value, label)
    end

    def require_sorted_unique!(values, label)
      return if values == values.sort && values == values.uniq

      raise Error, "#{label} must be sorted and unique"
    end

    def valid_label?(value)
      value.is_a?(String) && value.ascii_only? && SAFE_FIXTURE_LABEL.match?(value)
    end
  end
end
