# frozen_string_literal: true

# Experiment 3: an application-owned in-flight marker (compare-and-set on the
# domain row) versus the README recipe, when a job is re-run after the worker
# died mid-send (Sidekiq shutdown requeue, SIGKILL + reliable fetch, Solid
# Queue/GoodJob releasing a dead process's claimed jobs, a double enqueue).
#
#   bundle exec ruby 03_inflight_marker.rb
#
# PROTOTYPE CODE: illustrates the pattern; it is not a proposed gem API.

require "bundler/setup"
require "logger"
require "tmpdir"
require "active_record"
require "clicksend"
require "clicksend/testing"

db = File.join(Dir.mktmpdir, "marker.sqlite3")
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: db, pool: 5, timeout: 5000)
ActiveRecord::Base.logger = nil
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :notifications do |t|
    t.string :phone, null: false
    t.string :body, null: false
    t.string :sms_state, null: false, default: "pending" # pending | sending | sent | unknown | failed
    t.string :sms_message_id
    t.datetime :sms_claimed_at
  end
end

class Notification < ActiveRecord::Base; end

# Simulates the worker dying after ClickSend accepted the message but before
# the response was read (Sidekiq::Shutdown, SIGKILL, OOM, a deploy).
class WorkerDied < Exception; end # rubocop:disable Lint/InheritException

class DyingTransport
  def initialize(fake) = (@fake, @die = fake, true)
  def heal! = (@die = false)

  def call(...)
    response = @fake.call(...)
    raise WorkerDied if @die
    response
  end
end

FAKE = Clicksend::Testing::FakeAPI.new

def client(transport = FAKE) = Clicksend::Client.new(username: "t", api_key: "t", transport: transport,
  retry_policy: Clicksend::RetryPolicy.new(base_delay: 0, max_delay: 0))

# The README 1.1 recipe (no marker).
def readme_perform(sms, notification_id)
  n = Notification.find(notification_id)
  sms.deliver(to: n.phone, body: n.body, custom_string: "notification:#{n.id}")
rescue Clicksend::AmbiguousRequestError
  :reconcile
end

# Compare-and-set marker, committed *before* the HTTP call.
def marker_perform(sms, notification_id)
  claimed = Notification.where(id: notification_id, sms_state: "pending")
    .update_all(sms_state: "sending", sms_claimed_at: Time.now) == 1
  return :reconcile_or_skip unless claimed # someone else sent, is sending, or died mid-send

  n = Notification.find(notification_id)
  begin
    message = sms.deliver(to: n.phone, body: n.body, custom_string: "notification:#{n.id}")
    n.update_columns(sms_state: "sent", sms_message_id: message.message_id)
    :sent
  rescue Clicksend::AmbiguousRequestError
    n.update_columns(sms_state: "unknown")
    :reconcile
  rescue Clicksend::MessageRejected
    n.update_columns(sms_state: "failed")
    :rejected
  rescue Clicksend::Error
    n.update_columns(sms_state: "pending") # not processed: release the claim so a retry may send
    raise
  end
end

# The tempting variant: claim and send inside one transaction.
def transactional_perform(sms, notification_id)
  Notification.transaction do
    n = Notification.lock.find(notification_id)
    return :skip unless n.sms_state == "pending"

    n.update!(sms_state: "sending")
    sms.deliver(to: n.phone, body: n.body, custom_string: "notification:#{n.id}")
    n.update!(sms_state: "sent")
  end
end

def run(label, perform)
  FAKE.reset!
  id = Notification.create!(phone: "+61411111111", body: "hi").id
  transport = DyingTransport.new(FAKE)
  begin
    send(perform, client(transport).sms, id) # first run: worker dies mid-send
  rescue WorkerDied
  end
  transport.heal!
  second = send(perform, client(transport).sms, id) # the job runner re-runs the job
  puts format("%-56s accepted=%d state=%-8s second_run=%s",
    label, FAKE.sent_messages.size, Notification.find(id).sms_state, second.is_a?(Symbol) ? second.inspect : second.class.name)
end

puts "ActiveRecord #{ActiveRecord.version}, SQLite, clicksend #{Clicksend::VERSION}"
run("worker died mid-send, README recipe", :readme_perform)
run("worker died mid-send, claim inside a transaction", :transactional_perform)
run("worker died mid-send, committed compare-and-set marker", :marker_perform)

# A 429 (not processed) releases the claim, so the framework's retry can send.
FAKE.reset!
id = Notification.create!(phone: "+61411111111", body: "hi").id
FAKE.fail_next(status: 429, retry_after: 0, path: "/v3/sms/send", times: 3) # exhausts the gem's 2 retries
first = begin
  marker_perform(client.sms, id)
rescue Clicksend::RateLimitError => e
  "#{e.class} (retryable=#{e.retryable?})"
end
state_after_first = Notification.find(id).sms_state
second = marker_perform(client.sms, id)
puts format("%-56s accepted=%d first=%s state_between=%s second=%s",
  "429 then framework retry, marker", FAKE.sent_messages.size, first, state_after_first, second.inspect)

# Double enqueue: two workers run the same job at the same moment.
FAKE.reset!
id = Notification.create!(phone: "+61411111111", body: "hi").id
gate = Queue.new
results = Array.new(4) do
  Thread.new do
    gate.pop
    ActiveRecord::Base.connection_pool.with_connection { marker_perform(client.sms, id) }
  end
end
4.times { gate << :go }
tally = results.map(&:value).tally
puts format("%-56s accepted=%d results=%s", "4 concurrent runs of one job, marker", FAKE.sent_messages.size, tally)
