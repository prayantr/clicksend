# frozen_string_literal: true

RSpec.describe "Clicksend errors" do
  def info(idempotent:, method: :post, path: "/v3/sms/send", attempts: 1)
    Clicksend::RequestInfo.new(method: method, path: path, operation: "sms.deliver", idempotent: idempotent, attempts: attempts)
  end

  def with_request(error, idempotent:)
    error.request = info(idempotent: idempotent)
    error
  end

  describe Clicksend::RequestInfo do
    it "describes the call without its query string, credentials or body" do
      request = info(idempotent: false, attempts: 3)
      expect(request.to_s).to eq("POST /v3/sms/send")
      expect(request.inspect).to eq('#<Clicksend::RequestInfo POST /v3/sms/send operation="sms.deliver" idempotent=false attempts=3>')
      expect(request).to be_frozen
    end
  end

  describe "#message" do
    it "names the request it came from" do
      error = with_request(Clicksend::ServerError.new(http_status: 500), idempotent: false)
      expect(error.message).to eq("HTTP 500 (POST /v3/sms/send)")
      expect(error.full_message(highlight: false)).to include("HTTP 500 (POST /v3/sms/send)")
    end

    it "is unchanged for errors that did not come from a request" do
      expect(Clicksend::ConfigurationError.new("Missing ClickSend api_key").message).to eq("Missing ClickSend api_key")
    end
  end

  describe "#retryable? and #ambiguous?" do
    let(:refused) { Clicksend::ConnectionError.new("refused", request_sent: false) }
    let(:timeout) { Clicksend::TimeoutError.new("read") }

    {
      "a 429" => [-> { Clicksend::RateLimitError.new(http_status: 429) }, false, true],
      "a 429 on an idempotent request" => [-> { Clicksend::RateLimitError.new(http_status: 429) }, true, true],
      "a refused connection" => [-> { Clicksend::ConnectionError.new("x", request_sent: false) }, false, true],
      "a read timeout on an idempotent request" => [-> { Clicksend::TimeoutError.new("x") }, true, true],
      "a read timeout on a send" => [-> { Clicksend::TimeoutError.new("x") }, false, false],
      "a 5xx on an idempotent request" => [-> { Clicksend::ServerError.new(http_status: 503) }, true, true],
      "a 5xx on a send" => [-> { Clicksend::ServerError.new(http_status: 503) }, false, false],
      "a 400" => [-> { Clicksend::BadRequestError.new(http_status: 400) }, true, false],
      "a 401" => [-> { Clicksend::AuthenticationError.new(http_status: 401) }, true, false],
      "a malformed response" => [-> { Clicksend::MalformedResponseError.new("x") }, true, false]
    }.each do |description, (build, idempotent, retryable)|
      it "#{retryable ? "retries" : "does not retry"} #{description}" do
        expect(with_request(build.call, idempotent: idempotent).retryable?).to be(retryable)
      end
    end

    it "judges a connection failure without request context by whether it was sent" do
      expect(refused).to be_retryable
      expect(timeout).not_to be_retryable
    end

    it "never calls an ambiguous error retryable, whatever its class" do
      [Clicksend::RateLimitError.new(http_status: 429), refused, with_request(Clicksend::ServerError.new(http_status: 500), idempotent: true)].each do |error|
        error.extend(Clicksend::AmbiguousRequestError)
        expect(error).to be_ambiguous
        expect(error).not_to be_retryable
      end
    end

    it "makes ambiguous errors rescuable as AmbiguousRequestError while keeping their class" do
      error = with_request(Clicksend::TimeoutError.new("read"), idempotent: false).extend(Clicksend::AmbiguousRequestError)
      rescued = begin
        raise error
      rescue Clicksend::AmbiguousRequestError => e
        e
      end
      expect(rescued).to be_a(Clicksend::TimeoutError)
      expect(rescued.request_may_have_been_processed?).to be(true)
      expect(Clicksend::TimeoutError.new("x")).not_to be_ambiguous
    end

    it "never calls MessageRejected or ConfigurationError retryable" do
      result = Clicksend::SMS::Message.from_api("status" => "THROTTLED", "message_id" => "A")
      expect(Clicksend::MessageRejected.new(result)).not_to be_retryable
      expect(Clicksend::ConfigurationError.new("x")).not_to be_retryable
    end
  end

  describe "APIError#rate_limit" do
    it "reads the rate-limit headers of the failed response" do
      error = Clicksend::RateLimitError.new(http_status: 429, headers: {"x-ratelimit-limit" => "20", "x-ratelimit-remaining" => "0", "ratelimit-reset" => "39", "retry-after" => "39"})
      expect(error.rate_limit).to have_attributes(limit: 20, remaining: 0, reset_in: 39)
      expect(error.retry_after).to eq(39)
    end

    it "is nil without them" do
      expect(Clicksend::ServerError.new(http_status: 500).rate_limit).to be_nil
    end
  end
end
