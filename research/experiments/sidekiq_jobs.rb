# frozen_string_literal: true

# Jobs loaded by a real `sidekiq` process in experiment 2. They talk to the
# local stand-in ClickSend started by 02_sidekiq_semantics.rb (CLICKSEND_TEST_URL).

require "bundler/setup"
require "logger"
require "sidekiq"
require "active_job"
require "active_job/queue_adapters/sidekiq_adapter"
require "clicksend"

ActiveJob::Base.queue_adapter = :sidekiq
ActiveJob::Base.logger = Logger.new(nil)

CLIENT = Clicksend::Client.new(
  username: "u", api_key: "k", base_url: ENV.fetch("CLICKSEND_TEST_URL"),
  timeout: Float(ENV.fetch("CLIENT_TIMEOUT", "30")), max_retries: 0
)

def send_sms(ref) = CLIENT.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)

def note(*args) = Sidekiq.redis { |c| c.call("RPUSH", "notes", args.join(" ")) }

# Default Sidekiq options (retry: true, 25 retries).
class PlainSendJob
  include Sidekiq::Job

  def perform(ref) = send_sms(ref)
end

class DiscardAmbiguousJob
  include Sidekiq::Job

  sidekiq_retry_in { |_count, error, _msg| :discard if error.is_a?(Clicksend::AmbiguousRequestError) }
  def perform(ref) = send_sms(ref)
end

class KillAmbiguousJob
  include Sidekiq::Job

  sidekiq_retry_in { |_count, error, _msg| :kill if error.is_a?(Clicksend::AmbiguousRequestError) }
  sidekiq_retries_exhausted { |msg, error| note("exhausted", msg["class"], error.class.name, error.ambiguous?) }
  def perform(ref) = send_sms(ref)
end

# The README recipe, as a plain Sidekiq job.
class RecipeSendJob
  include Sidekiq::Job

  def perform(ref)
    send_sms(ref)
    note("sent", ref)
  rescue Clicksend::AmbiguousRequestError => e
    note("ambiguous-rescued", ref, e.class.name)
  end
end

# ActiveJob on the Sidekiq adapter: what happens after retry_on gives up.
class AjRetryOnJob < ActiveJob::Base
  retry_on Clicksend::Error, attempts: 2, wait: 0
  def perform(ref) = send_sms(ref)
end
