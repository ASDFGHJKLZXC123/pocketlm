#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "lib/m4_artifacts"

options = {
  expected_rc: nil,
  expected_model_sha256: nil,
  expected_collector_nonce: nil,
  expected_workload_version: nil,
  expected_suite: nil,
  output: nil,
  overwrite: false
}

parser = OptionParser.new do |option_parser|
  option_parser.banner = <<~USAGE
    Usage: #{File.basename($PROGRAM_NAME)} RUN_DIRECTORY \
      --expected-rc 40_HEX_COMMIT --expected-model-sha256 64_HEX_SHA256 \
      --expected-collector-nonce 32_HEX_NONCE \
      --expected-workload-version VERSION --expected-suite all|memory [options]
  USAGE
  option_parser.on("--expected-rc COMMIT", "Exact embedded 40-hex release-candidate commit") do |value|
    options[:expected_rc] = value
  end
  option_parser.on("--expected-model-sha256 SHA256", "Exact expected model SHA-256") do |value|
    options[:expected_model_sha256] = value
  end
  option_parser.on("--expected-collector-nonce NONCE", "Exact collector-generated 32-hex nonce") do |value|
    options[:expected_collector_nonce] = value
  end
  option_parser.on(
    "--expected-workload-version VERSION",
    "Exact workload profile: m4-workload-v1 or m4-workload-v2"
  ) do |value|
    options[:expected_workload_version] = value
  end
  option_parser.on("--expected-suite SUITE", "Exact suite profile: all or memory") do |value|
    options[:expected_suite] = value
  end
  option_parser.on("-o", "--output PATH", "Write the validated summary instead of stdout") do |value|
    options[:output] = value
  end
  option_parser.on("--overwrite", "Allow replacement of an existing --output file") do
    options[:overwrite] = true
  end
  option_parser.on("-h", "--help", "Show this help") do
    puts option_parser
    exit 0
  end
end

begin
  parser.parse!(ARGV)
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 2
end

required_options = %i[
  expected_rc
  expected_model_sha256
  expected_collector_nonce
  expected_workload_version
  expected_suite
]
if ARGV.length != 1 || required_options.any? { |key| options[key].nil? }
  warn(
    "RUN_DIRECTORY, --expected-rc, --expected-model-sha256, " \
    "--expected-collector-nonce, --expected-workload-version, and " \
    "--expected-suite are required."
  )
  warn parser
  exit 2
end
if options[:overwrite] && options[:output].nil?
  warn "--overwrite is valid only with --output."
  exit 2
end

run_directory = File.expand_path(ARGV.fetch(0))
if options[:output]
  output_path = File.expand_path(options[:output])
  if output_path.start_with?("#{run_directory}#{File::SEPARATOR}")
    warn "Validation summary must be written outside the immutable app-authored run directory."
    exit 2
  end
end

begin
  summary = PocketLMM4Artifacts::Validator.new(
    run_directory: run_directory,
    expected_rc: options.fetch(:expected_rc),
    expected_model_sha256: options.fetch(:expected_model_sha256),
    expected_collector_nonce: options.fetch(:expected_collector_nonce),
    expected_workload_version: options.fetch(:expected_workload_version),
    expected_suite: options.fetch(:expected_suite)
  ).validate!
  body = JSON.pretty_generate(summary) + "\n"

  if options[:output]
    output_path = File.expand_path(options.fetch(:output))
    flags = File::WRONLY | File::CREAT
    flags |= options[:overwrite] ? File::TRUNC : File::EXCL
    File.open(output_path, flags, 0o644) { |file| file.write(body) }
  else
    print body
  end
rescue PocketLMM4Artifacts::Error, Errno::EACCES, Errno::ENOENT => error
  warn "Qualification artifact validation failed: #{error.message}"
  exit 1
rescue Errno::EEXIST
  warn "Qualification artifact validation failed: output already exists; pass --overwrite to replace it."
  exit 1
end
