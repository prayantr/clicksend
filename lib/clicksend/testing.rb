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
  # An RSpec example. The application code sends one-time codes. When a send
  # is ambiguous it never sends again; it reports the outcome as unknown (and
  # might hand it to a reconciliation job):
  #
  #   class OtpSender
  #     def initialize(sms:) = @sms = sms
  #
  #     def call(phone:, code:, ref:)
  #       @sms.deliver(to: phone, body: "Your code is #{code}", custom_string: ref)
  #       :sent
  #     rescue Clicksend::AmbiguousRequestError
  #       :unknown
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
  #     # Both ambiguous cases must lead to the same, safe behaviour.
  #     [true, false].each do |processed|
  #       it "never sends twice when the outcome is unknown (processed: #{processed})" do
  #         fake.fail_next(:timeout, processed: processed, path: "/v3/sms/send")
  #
  #         expect(sender.call(phone: "+61411111111", code: "481516", ref: "otp:42")).to eq(:unknown)
  #         expect(fake.requests.count { |r| r.path == "/v3/sms/send" }).to eq(1)
  #         expect(fake.sent_messages.size).to eq(processed ? 1 : 0)
  #       end
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
  # History is not served (see FakeAPI). To test a reconciliation step, stub
  # it with the rows the scenario needs, for example none:
  #
  #   fake.stub(:get, "/v3/sms/history") do |_request|
  #     {"data" => {"total" => 0, "per_page" => 15, "current_page" => 1, "last_page" => 0, "data" => []}}
  #   end
  #
  # It also works as a development "dry run" transport, which is why the
  # client has no +dry_run:+ flag; nothing leaves the process:
  #
  #   client = Clicksend::Client.new(username: "dev", api_key: "dev", transport: Clicksend::Testing::FakeAPI.new)
  #
  # A FakeAPI keeps every request in memory until #reset!, so a long-running
  # process should reset it from time to time.
  #
  # Assertions for test frameworks are separate, opt-in files, and this gem
  # depends on neither framework: +require "clicksend/testing/rspec"+ adds
  # +have_sent_sms+ and +have_sent_no_sms+ (Clicksend::Testing::RSpecMatchers),
  # +require "clicksend/testing/minitest"+ adds +assert_sms_sent+ and
  # +assert_no_sms_sent+ (Clicksend::Testing::MinitestAssertions).
  module Testing
  end
end
