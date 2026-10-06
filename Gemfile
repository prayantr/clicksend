# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"
gem "webmock", "~> 3.26"
gem "simplecov", require: false
gem "standard", "~> 1.50", require: false
gem "bundler-audit", require: false
gem "json_schemer", "~> 2.4", require: false # contract tests against ClickSend's OpenAPI files
gem "activesupport", ">= 7.1", require: false # proves instrumenter: ActiveSupport::Notifications works as documented
gem "rack", ">= 3.0", require: false # replays webhook fixtures through Rack's own form/query parsing (spec/support/webhook_replay.rb)
gem "faraday-net_http_persistent", "~> 2.3", require: false # pins send safety with adapter: :net_http_persistent (spec/integration/persistent_connection_spec.rb)
