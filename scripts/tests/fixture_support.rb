# frozen_string_literal: true

require "digest"
require "json"

module PocketLMTestFixture
  module_function

  DEFAULT_TEMPLATE = <<~TEMPLATE.chomp
    {% for message in messages %}<|im_start|>{{ message['role'] }}
    {{ message['content'] }}<|im_end|>
    {% endfor %}{% if add_generation_prompt %}<|im_start|>assistant
    {% endif %}
  TEMPLATE

  DEFAULT_METADATA = {
    "general.architecture" => "qwen2",
    "general.file_type" => 15,
    "tokenizer.ggml.model" => "gpt2",
    "tokenizer.ggml.pre" => "qwen2",
    "tokenizer.chat_template" => DEFAULT_TEMPLATE,
    "tokenizer.ggml.tokens" => ["a", "b", "c"]
  }.freeze

  def write_gguf(path, metadata: DEFAULT_METADATA, magic: "GGUF", version: 3,
                 tensor_count: 0)
    File.open(path, "wb") do |file|
      file.write(magic)
      file.write([version].pack("L<"))
      file.write([tensor_count].pack("Q<"))
      file.write([metadata.length].pack("Q<"))
      metadata.each do |key, value|
        write_string(file, key)
        write_value(file, value)
      end
    end
    path
  end

  def write_catalog(path, model_path, model_overrides: {},
                    requirement_overrides: {})
    requirements = {
      "general.architecture" => "qwen2",
      "general.file_type" => 15,
      "tokenizer.ggml.model" => "gpt2",
      "tokenizer.ggml.pre" => "qwen2",
      "tokenizer.chat_template" => {
        "nonEmpty" => true,
        "contains" => ["<|im_start|>", "<|im_end|>", "add_generation_prompt"]
      }
    }.merge(requirement_overrides)
    revision = "a" * 40
    model = {
      "id" => "fixture-q4-k-m",
      "displayName" => "Fixture Q4_K_M",
      "family" => "qwen2",
      "repository" => "PocketLM/Fixture-GGUF",
      "revision" => revision,
      "artifactIntroducedRevision" => "b" * 40,
      "filename" => "fixture.gguf",
      "sourceUrl" => "https://huggingface.co/PocketLM/Fixture-GGUF/resolve/#{revision}/fixture.gguf",
      "byteSize" => File.size(model_path),
      "sha256" => Digest::SHA256.file(model_path).hexdigest,
      "ggufMagic" => "GGUF",
      "ggufVersion" => 3,
      "requiredMetadata" => requirements,
      "quantization" => "Q4_K_M",
      "parameterCountApproximate" => "fixture",
      "license" => "Apache-2.0",
      "licenseUrl" => "https://huggingface.co/PocketLM/Fixture-GGUF/blob/#{revision}/LICENSE",
      "gated" => false,
      "initialContextTokens" => 2_048,
      "chatTemplateSource" => "gguf_metadata",
      "chatTemplateVerified" => true,
      "appDirectoryName" => "fixture-q4km",
      "installedFilename" => "model.gguf"
    }.merge(model_overrides)
    File.write(path, JSON.pretty_generate("schemaVersion" => 1, "models" => [model]) + "\n")
    path
  end

  def write_string(file, value)
    bytes = value.encode(Encoding::UTF_8)
    file.write([bytes.bytesize].pack("Q<"))
    file.write(bytes)
  end

  def write_value(file, value)
    case value
    when String
      file.write([8].pack("L<"))
      write_string(file, value)
    when Integer
      file.write([4].pack("L<"))
      file.write([value].pack("L<"))
    when Array
      file.write([9].pack("L<"))
      file.write([8].pack("L<"))
      file.write([value.length].pack("Q<"))
      value.each { |element| write_string(file, element) }
    else
      raise ArgumentError, "unsupported fixture metadata value: #{value.inspect}"
    end
  end
end
