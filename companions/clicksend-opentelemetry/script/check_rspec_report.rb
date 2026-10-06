# frozen_string_literal: true

# Checks an RSpec JSON report (--format json --out FILE) in CI, after the run:
# nothing failed, something ran, and nothing was skipped, except with
# --allow-core-version-skips, examples skipped because the clicksend under test
# is older than they need (see spec_helper.rb). Prints what was skipped and why.
#
#   ruby script/check_rspec_report.rb tmp/rspec.json [--allow-core-version-skips]
require "json"

report = JSON.parse(File.read(ARGV.fetch(0)))
allow_core_skips = ARGV.include?("--allow-core-version-skips")
summary = report.fetch("summary")
pending = report.fetch("examples").select { |example| example["status"] == "pending" }

puts "#{summary["example_count"]} examples, #{summary["failure_count"]} failures, #{pending.size} skipped"
pending.each { |example| puts "  skipped: #{example["full_description"]} (#{example["pending_message"]})" }

unexpected = pending.reject { |example| allow_core_skips && example["pending_message"].to_s.start_with?("needs clicksend ") }
abort "Unexpected skipped examples: #{unexpected.size}" if unexpected.any?
abort "Failures" if summary["failure_count"].positive? || summary["errors_outside_of_examples_count"].positive?
abort "No examples ran" if summary["example_count"] == pending.size
