# frozen_string_literal: true

require "json"
require "securerandom"
require "uri"
require_relative "../clicksend"
require_relative "testing/records"
require_relative "testing/payloads"
require_relative "testing/failure"
require_relative "testing/fake_api"

module Clicksend
  # Test support: an in-memory ClickSend. Not loaded by +require "clicksend"+.
  #
  #   require "clicksend/testing"
  #
  # Clicksend::Testing::FakeAPI is a *transport*, so the code under test uses a
  # real Clicksend::Client: argument validation, error mapping, retry and
  # ambiguity rules and models are the production code paths. Only the HTTP
  # exchange is replaced. It does no I/O and sends nothing.
  #
  # An RSpec example. The application code sends one-time codes; when a send
  # is ambiguous it looks for its own +custom_string+ in history rather than
  # sending again:
  #
  #   class OtpSender
  #     def initialize(sms:) = @sms = sms
  #
  #     def call(phone:, code:, ref:)
  #       @sms.deliver(to: phone, body: "Your code is #{code}", custom_string: ref)
  #       :sent
  #     rescue Clicksend::AmbiguousRequestError
  #       history = @sms.history(to: phone, date_from: Time.now - 600)
  #       found = history.auto_paging_each.any? { |record| record.custom_string == ref }
  #       found ? :sent : :unknown
  #     end
  #   end
  #
  #   require "clicksend/testing"
  #
  #   RSpec.describe OtpSender do
  #     let(:fake) { Clicksend::Testing::FakeAPI.new }
  #     let(:sender) { OtpSender.new(sms: fake.client.sms) }
  #
  #     it "sends the code" do
  #       expect(sender.call(phone: "+61411111111", code: "481516", ref: "otp:42")).to eq(:sent)
  #       expect(fake.sent_messages.map { |m| [m.to, m.custom_string] }).to eq([["+61411111111", "otp:42"]])
  #     end
  #
  #     it "surfaces a rejected number" do
  #       fake.reject(to: "+61400000000", status: "INVALID_RECIPIENT")
  #       expect { sender.call(phone: "+61400000000", code: "1", ref: "otp:43") }.to raise_error(Clicksend::MessageRejected)
  #     end
  #
  #     it "finds a message that was accepted although the response was lost" do
  #       fake.fail_next(:timeout, processed: true, path: "/v3/sms/send") # processed, then the read times out
  #
  #       expect(sender.call(phone: "+61411111111", code: "481516", ref: "otp:42")).to eq(:sent)
  #       expect(fake.sent_messages.size).to eq(1) # sent once, never retried
  #       expect(fake.requests.map(&:path)).to eq(["/v3/sms/send", "/v3/sms/history"])
  #     end
  #
  #     # The fake's history is immediately consistent. ClickSend's is not
  #     # documented to be, so a missing row means "unknown", not "not sent".
  #     it "reports an unknown outcome when history has no trace of it" do
  #       fake.fail_next(:timeout, processed: false, path: "/v3/sms/send")
  #
  #       expect(sender.call(phone: "+61411111111", code: "481516", ref: "otp:42")).to eq(:unknown)
  #       expect(fake.sent_messages).to be_empty
  #     end
  #
  #     it "reads delivery receipts" do
  #       message = fake.client.sms.deliver(to: "+61411111111", body: "Hi")
  #       fake.add_receipt(for: fake.sent_messages.last, status_code: 301, error_text: "Expired")
  #
  #       expect(fake.client.sms.receipt(message.message_id)).to be_failed
  #     end
  #   end
  #
  # It also works as a development "dry run" transport, which is why the
  # client has no +dry_run:+ flag; nothing leaves the process:
  #
  #   client = Clicksend::Client.new(username: "dev", api_key: "dev", transport: Clicksend::Testing::FakeAPI.new)
  #
  # A FakeAPI keeps every request in memory until #reset!, so a long-running
  # process should reset it from time to time.
  module Testing
  end
end
