# frozen_string_literal: true

require "fileutils"
require "net/http"

# Optional checks against the real ClickSend API. Never part of normal CI.
#
#   CLICKSEND_LIVE=1 CLICKSEND_USERNAME=... CLICKSEND_API_KEY=... bundle exec rspec --tag live
#
# Optional: CLICKSEND_TEST_ACCOUNTS_API_KEY, the key ClickSend publishes for its
# "nocredit", "notactive" and "banned" test accounts
# (https://developers.clicksend.com/docs/testing).
#
# Safety rules:
# - Messages go only to ClickSend's documented test number +61411111111 ("No
#   messages will be sent, and your account won't be charged") or to an
#   invalid number ("+000") that cannot be delivered.
# - Mark-read calls only ever send date_before: 1 (a cutoff in 1970), so they
#   cannot mark any real receipt or reply as read.
# - Rate limits are only provoked without credentials, and last.
# - Output shows response shapes, types and status codes only: never
#   credentials, usernames, balances, real phone numbers or message bodies.
#   Observations are also written to tmp/live-observations.json (git-ignored).
module LiveSpec
  TEST_NUMBER = "+61411111111"
  INVALID_NUMBER = "+000"
  TEST_ACCOUNTS = %w[nocredit notactive banned].freeze
  SAFE_VALUES = %w[http_code response_code response_msg status status_code status_text error_code error_text
    message_type message_parts message_price direction].freeze
  OBSERVATIONS = {}
  STATE = {}
end

RSpec.describe "ClickSend live API", :live, order: :defined do
  before(:context) do
    WebMock.allow_net_connect!
  end

  after(:context) do
    WebMock.disable_net_connect!
    path = File.expand_path("../../tmp/live-observations.json", __dir__)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(LiveSpec::OBSERVATIONS))
  end

  before do |example|
    credentials = ENV["CLICKSEND_USERNAME"] && ENV["CLICKSEND_API_KEY"]
    skip "set CLICKSEND_USERNAME and CLICKSEND_API_KEY" unless credentials || example.metadata[:no_credentials]
  end

  let(:client) { Clicksend::Client.new(logger: Logger.new($stdout), max_retries: 0) }

  # --- helpers: describe values without revealing them ----------------------

  def shape(value, key = nil)
    case value
    when Hash then value.to_h { |k, v| [k, shape(v, k)] }
    when Array then value.first(2).map { |v| shape(v) }
    else LiveSpec::SAFE_VALUES.include?(key) ? value : value.class.name
    end
  end

  def id_format(id)
    id.to_s.gsub(/[0-9A-F]/, "H").gsub(/[a-f]/, "h")
  end

  def rate_limit_headers(headers)
    headers.select { |name, _| name.match?(/ratelimit|retry-after/) }
  end

  def error_summary(error)
    if error.is_a?(Clicksend::MessageRejected)
      return {class: error.class.name, status: error.status, price: error.result.price, shape: shape(error.result.raw)}
    end

    {class: error.class.name, http_status: error.respond_to?(:http_status) ? error.http_status : nil,
     response_code: error.respond_to?(:response_code) ? error.response_code : nil,
     response_msg: error.respond_to?(:response_msg) ? error.response_msg : nil,
     body: error.respond_to?(:body) ? shape(error.body) : nil}
  end

  def observe(label, value)
    LiveSpec::OBSERVATIONS[label] = value
    puts "  [observed] #{label}: #{JSON.generate(value)}"
  end

  def outcome
    yield
  rescue Clicksend::Error => e
    e
  end

  # --- your account ----------------------------------------------------------

  it "L1 GET /v3/account (wrapped)" do
    account = client.account.fetch
    observe("account.shape", shape(account.raw))
    expect(account.balance).to match(/\A-?\d+(\.\d+)?\z/)
  end

  it "L2 GET /v3/account (escape hatch, for headers)" do
    response = client.request(:get, "/v3/account")
    observe("account.http_status", response.http_status)
    observe("authenticated.rate_limit_headers", rate_limit_headers(response.headers))
    expect(response.http_status).to eq(200)
  end

  it "L3 POST /v3/sms/send: one message to the test number" do
    message = outcome { client.sms.deliver(to: LiveSpec::TEST_NUMBER, body: "clicksend-ruby live test", custom_string: "live-test") }
    next observe("send.test_number.error", error_summary(message)) if message.is_a?(Clicksend::Error)

    observe("send.test_number.message_shape", shape(message.raw))
    observe("send.test_number.message_id_format", id_format(message.message_id))
    observe("send.test_number.date", {class: message.raw["date"].class.name, parsed: !message.sent_at.nil?})
    observe("send.test_number.schedule", {class: message.raw["schedule"].class.name, value: message.raw["schedule"].inspect[0, 12]})
    LiveSpec::STATE[:test_message_id] = message.message_id
    expect(message).to be_queued
  end

  it "L4 POST /v3/sms/send: test number plus an invalid recipient (batch)" do
    result = outcome { client.sms.deliver_batch([{to: LiveSpec::TEST_NUMBER, body: "ok"}, {to: LiveSpec::INVALID_NUMBER, body: "invalid"}]) }
    if result.is_a?(Clicksend::SMS::Batch)
      observe("batch_invalid.result", {queued_count: result.queued_count, blocked_count: result.blocked_count,
        total_count: result.total_count, statuses: result.map(&:status), prices: result.map(&:price),
        message_id_formats: result.map { |m| id_format(m.message_id) }})
      observe("batch_invalid.rejected_shape", shape(result.rejected.first&.raw))
    else
      observe("batch_invalid.error", error_summary(result))
    end
    expect(result).to be_a(Clicksend::SMS::Batch).or be_a(Clicksend::APIError)
  end

  it "L5 POST /v3/sms/send: invalid recipient alone" do
    result = outcome { client.sms.deliver(to: LiveSpec::INVALID_NUMBER, body: "invalid") }
    summary = case result
    when Clicksend::MessageRejected then {class: result.class.name, status: result.status, price: result.result.price, shape: shape(result.result.raw)}
    when Clicksend::Error then error_summary(result)
    else {class: result.class.name, status: result.status}
    end
    observe("single_invalid.outcome", summary)
    expect(result).to be_a(Clicksend::Error)
  end

  it "L6 GET /v3/sms/receipts?limit=15" do
    page = client.sms.receipts(limit: 15)
    observe("receipts.page", {total: page.total, per_page: page.per_page, current_page: page.current_page, last_page: page.last_page})
    observe("receipts.item_shape", shape(page.first&.raw))
    observe("receipts.status_code_class", page.first&.raw&.dig("status_code").class.name)
    expect(page).to be_a(Clicksend::Page)
  end

  it "L7 GET /v3/sms/receipts/{id} for the test message" do
    skip "no test message id from L3" unless LiveSpec::STATE[:test_message_id]
    result = outcome { client.sms.receipt(LiveSpec::STATE[:test_message_id]) }
    observe("receipt_lookup.outcome", result.is_a?(Clicksend::SMS::Receipt) ? shape(result.raw) : error_summary(result))
  end

  it "L8 GET /v3/sms/inbound?limit=15" do
    page = client.sms.inbound(limit: 15)
    observe("inbound.page", {total: page.total, per_page: page.per_page})
    observe("inbound.item_shape", shape(page.first&.raw))
    expect(page).to be_a(Clicksend::Page)
  end

  it "L9 PUT /v3/sms/receipts-read {date_before: 1}" do
    result = outcome { client.sms.mark_receipts_read(before: 1) }
    observe("receipts_read.cutoff_1970", result.nil? ? "accepted" : error_summary(result))
  end

  it "L10 PUT /v3/sms/inbound-read {date_before: 1}" do
    result = outcome { client.sms.mark_inbound_read(before: 1) }
    observe("inbound_read.cutoff_1970", result.nil? ? "accepted" : error_summary(result))
  end

  it "L11 GET /v3/account with a dummy API key" do
    result = outcome { client.with(api_key: "00000000-0000-0000-0000-000000000000").account.fetch }
    observe("bad_key.outcome", error_summary(result).merge(rate_limit_headers: rate_limit_headers(result.headers)))
    expect(result).to be_a(Clicksend::AuthenticationError)
  end

  # --- ClickSend's public test accounts --------------------------------------

  LiveSpec::TEST_ACCOUNTS.each_with_index do |username, index|
    it "L#{12 + index * 2} GET /v3/account as #{username}" do
      skip "set CLICKSEND_TEST_ACCOUNTS_API_KEY" unless ENV["CLICKSEND_TEST_ACCOUNTS_API_KEY"]
      test_client = Clicksend::Client.new(username: username, api_key: ENV["CLICKSEND_TEST_ACCOUNTS_API_KEY"], max_retries: 0)
      result = outcome { test_client.request(:get, "/v3/account") }
      observe("#{username}.account", result.is_a?(Clicksend::Response) ? {http_status: result.http_status, response_code: result.response_code, shape: shape(result.data)} : error_summary(result))
    end

    it "L#{13 + index * 2} POST /v3/sms/send to the test number as #{username}" do
      skip "set CLICKSEND_TEST_ACCOUNTS_API_KEY" unless ENV["CLICKSEND_TEST_ACCOUNTS_API_KEY"]
      test_client = Clicksend::Client.new(username: username, api_key: ENV["CLICKSEND_TEST_ACCOUNTS_API_KEY"], max_retries: 0)
      result = outcome { test_client.request(:post, "/v3/sms/send", body: {messages: [{to: LiveSpec::TEST_NUMBER, body: "clicksend-ruby live test"}]}) }
      observe("#{username}.send", result.is_a?(Clicksend::Response) ? {http_status: result.http_status, response_code: result.response_code, shape: shape(result.body)} : error_summary(result))
    end
  end

  # --- unauthenticated rate limit (last) --------------------------------------

  it "L18 unauthenticated GET /v3/account until 429 (at most 25 requests)", :no_credentials do
    uri = URI("https://rest.clicksend.com/v3/account")
    statuses = []
    limited = nil
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
      25.times do
        response = http.request(Net::HTTP::Get.new(uri, "Accept" => "application/json"))
        statuses << response.code.to_i
        if response.code == "429"
          limited = response
          break
        end
      end
    end
    observe("unauthenticated.statuses", statuses.tally)
    next observe("unauthenticated.429", "not reached in 25 requests") unless limited

    headers = limited.each_header.to_h
    observe("unauthenticated.429", {headers: rate_limit_headers(headers), body: limited.body})

    # Feed the real 429 through the gem's response handling (no extra request).
    transport = Struct.new(:raw) { def call(*, **) = raw }.new(
      Clicksend::Transport::Response.new(status: 429, headers: headers.freeze, body: limited.body.to_s)
    )
    error = outcome { Clicksend::Client.new(username: "u", api_key: "k", transport: transport, max_retries: 0).request(:get, "/v3/account") }
    observe("unauthenticated.429_as_mapped", {class: error.class.name, retry_after: error.retry_after, response_code: error.response_code})
    expect(error).to be_a(Clicksend::RateLimitError)
  end
end
