# frozen_string_literal: true

# Experiment 1: how ActiveJob's retry_on / discard_on interact with
# Clicksend::AmbiguousRequestError, and whether a job-level concern can
# enforce "an ambiguous send is never retried by the framework" better than
# the README recipe.
#
#   bundle exec ruby 01_activejob_retry_semantics.rb
#
# Jobs run through ActiveJob's TestAdapter; each enqueued job (including the
# re-enqueue done by retry_on) is executed with ActiveJob::Base.execute, the
# same entry point every queue adapter uses.

require "bundler/setup"
require "logger"
require "active_job"
require "clicksend"
require "clicksend/testing"

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)
FAKE = Clicksend::Testing::FakeAPI.new
CLIENT = FAKE.client

# TestAdapter keeps job.serialize (String keys) merged with Symbol-keyed
# bookkeeping (:job, :queue, :at, ...); execute the serialized part.
def run_all
  adapter = ActiveJob::Base.queue_adapter
  runs = 0
  escaped = nil
  until adapter.enqueued_jobs.empty?
    payload = adapter.enqueued_jobs.shift
    runs += 1
    data = payload.reject { |key, _| key.is_a?(Symbol) }
    begin
      ActiveJob::Base.execute(data)
    rescue => e
      escaped = e
    end
  end
  [runs, escaped]
end

def scenario(name)
  FAKE.reset!
  ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  yield
  runs, escaped = run_all
  sends = FAKE.requests.count { |r| r.path == "/v3/sms/send" }
  puts format("%-62s runs=%d send_requests=%d accepted=%d escaped=%s",
    name, runs, sends, FAKE.sent_messages.size, escaped&.class&.name || "-")
end

class ApplicationJob < ActiveJob::Base; end

# A: the "obvious" job most people write first.
class NaiveJob < ApplicationJob
  retry_on Clicksend::Error, attempts: 3, wait: 0
  def perform(ref) = CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)
end

# B: README recipe (1.1).
class ReadmeJob < ApplicationJob
  retry_on Clicksend::Error, attempts: 3, wait: 0
  discard_on Clicksend::MessageRejected
  def perform(ref)
    CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)
  rescue Clicksend::AmbiguousRequestError
    RECONCILED << ref
  end
end

# C: discard_on with the *module* declared after retry_on (bottom-up wins).
class DiscardAfterJob < ApplicationJob
  retry_on Clicksend::Error, attempts: 3, wait: 0
  discard_on Clicksend::AmbiguousRequestError
  def perform(ref) = CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)
end

# D: the same two lines in the other order.
class DiscardBeforeJob < ApplicationJob
  discard_on Clicksend::AmbiguousRequestError
  retry_on Clicksend::Error, attempts: 3, wait: 0
  def perform(ref) = CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)
end

# E: a common ApplicationJob-wide policy inherited by a send job.
class GreedyApplicationJob < ActiveJob::Base
  retry_on StandardError, attempts: 3, wait: 0
end

class InheritedGreedyJob < GreedyApplicationJob
  discard_on Clicksend::AmbiguousRequestError # declared in the subclass, so it is checked first
  def perform(ref) = CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)
end

# F: PROTOTYPE ONLY (not a proposed implementation): a concern that intercepts
# ambiguity in around_perform, i.e. *inside* the code rescue_from handlers
# wrap, so no retry_on/discard_on declaration order can reach it.
module SendsSmsPrototype
  extend ActiveSupport::Concern

  included do
    around_perform do |job, block|
      block.call
    rescue Clicksend::AmbiguousRequestError => e
      begin
        job.on_ambiguous_sms(e)
      rescue => hook_error
        HOOK_ERRORS << hook_error.class.name # logged, never re-raised
      end
    end
  end
  def on_ambiguous_sms(_error) = nil
end
HOOK_ERRORS = []
RECONCILED = []

class ConcernGreedyJob < GreedyApplicationJob
  include SendsSmsPrototype

  def perform(ref) = CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)
  def on_ambiguous_sms(_error) = raise("reconciliation enqueue failed")
end

# G: retry_on exhaustion for a *non*-ambiguous error re-raises to the adapter.
class ExhaustJob < ApplicationJob
  retry_on Clicksend::Error, attempts: 2, wait: 0
  def perform(ref) = CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)
end

puts "ActiveJob #{ActiveJob.version}, clicksend #{Clicksend::VERSION}"
puts "rescue_from accepts the AmbiguousRequestError module: #{DiscardAfterJob.rescue_handlers.map(&:first).inspect}"

scenario("A naive retry_on Clicksend::Error, timeout processed:true") do
  FAKE.fail_next(:timeout, processed: true, path: "/v3/sms/send")
  NaiveJob.perform_later("a")
end
scenario("A naive retry_on Clicksend::Error, 500 processed:true") do
  FAKE.fail_next(status: 500, processed: true, path: "/v3/sms/send")
  NaiveJob.perform_later("a2")
end
scenario("B README recipe, timeout processed:true") do
  FAKE.fail_next(:timeout, processed: true, path: "/v3/sms/send")
  ReadmeJob.perform_later("b")
end
scenario("C retry_on then discard_on(module), timeout processed:true") do
  FAKE.fail_next(:timeout, processed: true, path: "/v3/sms/send")
  DiscardAfterJob.perform_later("c")
end
scenario("D discard_on(module) then retry_on, timeout processed:true") do
  FAKE.fail_next(:timeout, processed: true, path: "/v3/sms/send")
  DiscardBeforeJob.perform_later("d")
end
scenario("E parent retry_on StandardError + child discard_on, ambiguous") do
  FAKE.fail_next(:timeout, processed: true, path: "/v3/sms/send")
  InheritedGreedyJob.perform_later("e")
end
scenario("F prototype concern under retry_on StandardError, ambiguous") do
  FAKE.fail_next(:timeout, processed: true, path: "/v3/sms/send")
  ConcernGreedyJob.perform_later("f")
end
puts "   F hook errors swallowed: #{HOOK_ERRORS.inspect}"
scenario("G retry_on attempts:2, persistent 429 (not processed)") do
  FAKE.fail_next(status: 429, retry_after: 0, path: "/v3/sms/send", times: 50)
  ExhaustJob.perform_later("g")
end
