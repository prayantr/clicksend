# frozen_string_literal: true

require "clicksend/testing"

RSpec.describe Clicksend::Testing::FakeAPI, "#fail_next(:interrupted)" do
  let(:fake) { described_class.new }
  let(:client) { fake.client }

  def deliver(sms = client.sms)
    sms.deliver(to: "+61411111111", body: "Your code is 481516", custom_string: "otp:42")
  end

  describe Clicksend::Testing::SimulatedInterrupt do
    it "is an Exception the client and job runners' `rescue => e` don't catch, and not an ::Interrupt" do
      expect(described_class.ancestors).to include(Exception)
      expect(described_class.ancestors).not_to include(StandardError, Clicksend::Error, Interrupt, SignalException)
    end
  end

  context "with processed: true (stopped after ClickSend accepted the message)" do
    it "raises SimulatedInterrupt untouched, with the message accepted exactly once and nothing retried" do
      fake.fail_next(:interrupted, processed: true)

      expect { deliver }.to raise_error(Clicksend::Testing::SimulatedInterrupt, /after ClickSend processed it.*models the job runner, not ClickSend/)
      expect(fake.sent_messages.map(&:custom_string)).to eq(["otp:42"])
      expect(fake.requests.map(&:path)).to eq(["/v3/sms/send"])
    end
  end

  context "with processed: false (stopped before ClickSend processed it)" do
    it "raises SimulatedInterrupt, records the request and accepts nothing" do
      fake.fail_next(:interrupted, processed: false)

      expect { deliver }.to raise_error(Clicksend::Testing::SimulatedInterrupt, /before ClickSend processed it/)
      expect(fake.sent_messages).to be_empty
      expect(fake.requests.size).to eq(1)
    end
  end

  [true, false].each do |processed|
    it "is never retried, even for an idempotent request and generous retries (processed: #{processed})" do
      fake.fail_next(:interrupted, processed: processed)

      expect { fake.client(max_retries: 5).sms.receipts }.to raise_error(Clicksend::Testing::SimulatedInterrupt)
      expect(fake.requests.size).to eq(1)
    end

    it "passes through the instrumenter's block untouched (processed: #{processed})" do
      seen = []
      instrumenter = Object.new
      instrumenter.define_singleton_method(:instrument) do |name, payload = {}, &block|
        block.call(payload)
      rescue Exception => e # rubocop:disable Lint/RescueException
        seen << [name, e.class]
        raise
      end
      fake.fail_next(:interrupted, processed: processed)

      expect { deliver(fake.client(instrumenter: instrumenter).sms) }.to raise_error(Clicksend::Testing::SimulatedInterrupt)
      expect(seen).to eq([["request.clicksend", Clicksend::Testing::SimulatedInterrupt]])
      expect(fake.sent_messages.size).to eq(processed ? 1 : 0)
    end
  end

  it "only fails matching requests, and as many times as asked" do
    fake.fail_next(:interrupted, processed: true, path: "/v3/sms/send", times: 2)

    expect(client.account.fetch.balance).to eq("10.000000")
    2.times { expect { deliver }.to raise_error(Clicksend::Testing::SimulatedInterrupt) }
    expect(deliver).to be_queued
    expect(fake.sent_messages.size).to eq(3)
  end

  it "requires processed: true or false, and takes no status: or retry_after:" do
    expect { fake.fail_next(:interrupted) }.to raise_error(ArgumentError, /fail_next\(:interrupted\) needs processed: true or false/)
    expect { fake.fail_next(:interrupted, processed: nil) }.to raise_error(ArgumentError, /needs processed:/)
    expect { fake.fail_next(:interrupted, status: 500, processed: true) }.to raise_error(ArgumentError, /not both/)
    expect { fake.fail_next(:interrupted, processed: true, retry_after: 1) }.to raise_error(ArgumentError, /only applies to status: 429/)
    expect { fake.fail_next(:interupted, processed: true) }.to raise_error(ArgumentError, /use one of .*:interrupted/)
  end

  # What the helper is for: a job that marks the send as in flight (on the
  # application's own row) before calling ClickSend, so that the run after an
  # interruption never sends again.
  describe "testing an in-flight marker with it" do
    let(:job) do
      Class.new do
        attr_reader :state

        def initialize(sms) = (@sms, @state = sms, "pending")

        def perform
          return :reconcile unless @state == "pending" # a previous run may have sent it

          @state = "sending" # committed before the call in a real app
          @sms.deliver(to: "+61411111111", body: "Your code is 481516", custom_string: "otp:42")
          @state = "sent"
        rescue Clicksend::AmbiguousRequestError
          @state = "unknown"
        end
      end.new(client.sms)
    end

    [true, false].each do |processed|
      it "the re-run after the worker is stopped mid-send does not send again (processed: #{processed})" do
        fake.fail_next(:interrupted, processed: processed, path: "/v3/sms/send")

        expect { job.perform }.to raise_error(Clicksend::Testing::SimulatedInterrupt) # the job runner requeues it
        expect(job.state).to eq("sending")
        expect(job.perform).to eq(:reconcile)

        expect(fake.requests.count { |request| request.path == "/v3/sms/send" }).to eq(1)
        expect(fake.sent_messages.size).to eq(processed ? 1 : 0)
      end
    end
  end
end
