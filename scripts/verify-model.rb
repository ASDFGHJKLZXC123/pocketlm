#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require_relative "lib/pocketlm_model"

DEFAULT_CATALOG = File.expand_path("../models/catalog.json", __dir__)

def parser_for(command, options)
  OptionParser.new do |parser|
    parser.banner = "Usage: #{File.basename($PROGRAM_NAME)} #{command} [options]"
    parser.on("--catalog PATH", "Catalog path (default: models/catalog.json)") do |path|
      options[:catalog] = path
    end
    yield parser if block_given?
  end
end

def parse!(parser, arguments)
  parser.parse!(arguments)
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 2
end

def emit_json(value)
  puts JSON.pretty_generate(value)
end

command = ARGV.shift

begin
  case command
  when "catalog"
    options = { catalog: DEFAULT_CATALOG, format: "json" }
    parser = parser_for(command, options) do |option_parser|
      option_parser.on("--format FORMAT", %w[json tsv], "Output format: json or tsv") do |format|
        options[:format] = format
      end
    end
    parse!(parser, ARGV)
    unless ARGV.empty?
      warn parser
      exit 2
    end

    catalog = PocketLMModel.load_catalog(options[:catalog])
    model = catalog.model
    if options[:format] == "tsv"
      fields = [
        model["id"], model["filename"], model["sourceUrl"], model["byteSize"],
        model["sha256"], model["ggufMagic"], model["ggufVersion"],
        model["appDirectoryName"], model["installedFilename"], catalog.schema_version
      ]
      if fields.any? { |field| field.to_s.match?(/[\t\r\n]/) }
        raise PocketLMModel::Error, "catalog fields cannot be represented as TSV"
      end
      puts fields.join("\t")
    else
      emit_json("schemaVersion" => catalog.schema_version, "model" => model)
    end
  when "verify"
    options = { catalog: DEFAULT_CATALOG, json: false }
    parser = parser_for(command, options) do |option_parser|
      option_parser.on("--json", "Emit the verification record as JSON") do
        options[:json] = true
      end
    end
    parse!(parser, ARGV)
    if ARGV.length != 1
      warn "A model path is required."
      warn parser
      exit 2
    end

    path = ARGV.fetch(0)
    catalog = PocketLMModel.load_catalog(options[:catalog])
    result = PocketLMModel.verify_model!(path, catalog)
    if options[:json]
      emit_json(result)
    else
      puts "Verified model: #{result.fetch('path')}"
      puts "SHA-256: #{result.fetch('sha256')}"
      puts "GGUF: version #{result.fetch('ggufVersion')}, " \
           "#{result.fetch('tensorCount')} tensors, " \
           "#{result.fetch('metadataCount')} metadata entries"
    end
  when "manifest"
    options = {
      catalog: DEFAULT_CATALOG,
      installed_at: nil,
      backup_excluded: false,
      output: nil
    }
    parser = parser_for(command, options) do |option_parser|
      option_parser.on("--installed-at TIMESTAMP", "ISO-8601 installation time") do |timestamp|
        options[:installed_at] = timestamp
      end
      option_parser.on("--backup-excluded", "Record successful backup exclusion") do
        options[:backup_excluded] = true
      end
      option_parser.on("--output PATH", "Write the manifest to PATH") do |path|
        options[:output] = path
      end
    end
    parse!(parser, ARGV)
    unless ARGV.empty? && options[:installed_at]
      warn "--installed-at is required and positional arguments are not accepted."
      warn parser
      exit 2
    end
    unless options[:backup_excluded]
      raise PocketLMModel::Error, "manifest cannot be created before backup exclusion succeeds"
    end

    catalog = PocketLMModel.load_catalog(options[:catalog])
    body = JSON.pretty_generate(
      PocketLMModel.manifest(
        catalog,
        installed_at: options[:installed_at],
        backup_excluded: true
      )
    ) + "\n"
    if options[:output]
      File.open(options[:output], "wb", 0o600) { |file| file.write(body) }
    else
      print body
    end
  when "verify-manifest"
    options = { catalog: DEFAULT_CATALOG, json: false }
    parser = parser_for(command, options) do |option_parser|
      option_parser.on("--json", "Emit the validated manifest as JSON") do
        options[:json] = true
      end
    end
    parse!(parser, ARGV)
    if ARGV.length != 1
      warn "A manifest path is required."
      warn parser
      exit 2
    end

    catalog = PocketLMModel.load_catalog(options[:catalog])
    manifest = PocketLMModel.verify_manifest!(ARGV.fetch(0), catalog)
    if options[:json]
      emit_json(manifest)
    else
      puts "Verified manifest: #{File.expand_path(ARGV.fetch(0))}"
    end
  else
    warn <<~USAGE
      Usage: #{File.basename($PROGRAM_NAME)} COMMAND [options]

      Commands:
        catalog          Validate and print the one-model catalog
        verify           Verify a GGUF against the pinned catalog
        manifest         Build an installation manifest
        verify-manifest  Verify an installation manifest
    USAGE
    exit 2
  end
rescue PocketLMModel::Error => error
  warn "Verification failed: #{error.message}"
  exit 1
rescue Errno::EACCES => error
  warn "Verification failed: #{error.message}"
  exit 1
rescue Errno::ENOENT => error
  warn "Verification failed: #{error.message}"
  exit 1
end
