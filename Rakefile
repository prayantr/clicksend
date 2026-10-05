# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "standard/rake"

RSpec::Core::RakeTask.new(:spec)

namespace :contract do
  desc "Download ClickSend's published OpenAPI files into tmp/openapi"
  task :fetch do
    ruby "script/fetch_openapi.rb"
  end

  desc "Run contract specs against ClickSend's published OpenAPI files (needs network)"
  task run: :fetch do
    sh({"CLICKSEND_CONTRACT" => "1", "COVERAGE" => "0"}, "bundle exec rspec --tag contract")
  end
end

desc "Run contract specs (downloads ClickSend's OpenAPI files)"
task contract: "contract:run"

task default: %i[spec standard]
