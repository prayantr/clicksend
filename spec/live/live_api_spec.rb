# frozen_string_literal: true

# Optional checks against the real ClickSend API. Never part of normal CI.
#
#   CLICKSEND_LIVE=1 CLICKSEND_USERNAME=... CLICKSEND_API_KEY=... bundle exec rspec --tag live
#
# Sends go only to ClickSend's documented test number +61411111111, for
# which "No messages will be sent, and your account won't be charged"
# (https://developers.clicksend.com/docs/testing). Each example prints what
# ClickSend actually returned, to settle behaviour the docs leave open.
RSpec.describe "ClickSend live API", :live do
  let(:test_number) { "+61411111111" }

  before do
    WebMock.allow_net_connect!
    skip "set CLICKSEND_USERNAME and CLICKSEND_API_KEY" unless ENV["CLICKSEND_USERNAME"] && ENV["CLICKSEND_API_KEY"]
  end

  after { WebMock.disable_net_connect! }

  let(:client) { Clicksend::Client.new(logger: Logger.new($stdout)) }

  def observe(label, value)
    puts "  [observed] #{label}: #{value.inspect}"
  end

  it "fetches the account" do
    account = client.account.fetch
    observe("account", account)
    expect(account.balance).to match(/\A-?\d+(\.\d+)?\z/)
  end

  it "sends to ClickSend's test number" do
    message = client.sms.deliver(to: test_number, body: "clicksend-ruby live test", custom_string: "live-#{Time.now.to_i}")
    observe("message", message)
    expect(message).to be_queued
    expect(message.message_id).to match(Clicksend::Resources::SMS::MESSAGE_ID)
  end

  it "reports a per-message failure for an invalid recipient" do
    outcome =
      begin
        client.sms.deliver_batch([{to: test_number, body: "ok"}, {to: "+000", body: "bad"}])
      rescue Clicksend::APIError => e
        e
      end
    observe("invalid recipient outcome", outcome.is_a?(Clicksend::APIError) ? [outcome.class, outcome.http_status, outcome.response_code] : outcome.rejected.map(&:status))
    expect(outcome).to be_a(Clicksend::SMS::Batch).or be_a(Clicksend::APIError)
  end

  it "lists receipts and replies" do
    receipts = client.sms.receipts(limit: 15)
    inbound = client.sms.inbound(limit: 15)
    observe("receipts page", receipts)
    observe("inbound page", inbound)
    expect([receipts, inbound]).to all(be_a(Clicksend::Page))
  end

  it "rejects bad credentials with AuthenticationError" do
    bad = client.with(api_key: "00000000-0000-0000-0000-000000000000")
    expect { bad.account.fetch }.to raise_error(Clicksend::AuthenticationError) { |e| observe("401", [e.response_code, e.response_msg]) }
  end
end
