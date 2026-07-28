#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

abort "usage: #{$PROGRAM_NAME} /path/to/pocketlm_qualify" unless ARGV.length == 1

stdout, stderr, status = Open3.capture3(ARGV.fetch(0), "--self-test-fatal-timeout")
abort "fatal-timeout self-test wrote stdout" unless stdout.empty?
abort "fatal-timeout self-test exited #{status.exitstatus.inspect}, expected 124" unless status.exitstatus == 124

lines = stderr.lines.reject { |line| line.strip.empty? }
abort "fatal-timeout self-test emitted no record" if lines.empty?

record = JSON.parse(lines.last)
expected = {
  "schema_version" => 1,
  "tool" => "pocketlm_qualify",
  "record_type" => "fatal_timeout",
  "request_id" => 7,
  "generation_timeout_ms" => 1,
  "terminal_grace_ms" => 1,
  "exit_code" => 124,
  "reason" => "terminal_missing_after_cancel"
}
abort "unexpected fatal-timeout record: #{record.inspect}" unless record == expected

puts "Qualification fatal-timeout self-test passed."

stdout, stderr, status = Open3.capture3(ARGV.fetch(0), "--self-test-timeout-predicate")
abort "timeout-predicate self-test wrote stderr: #{stderr}" unless stderr.empty?
abort "timeout-predicate self-test failed with #{status.exitstatus.inspect}" unless status.success?

record = JSON.parse(stdout)
expected = {
  "schema_version" => 1,
  "tool" => "pocketlm_qualify",
  "record_type" => "timeout_predicate_self_test",
  "synthetic_timed_out" => true,
  "predicate_accepted" => false,
  "passed" => true
}
abort "unexpected timeout-predicate record: #{record.inspect}" unless record == expected

puts "Qualification timeout-predicate self-test passed."
