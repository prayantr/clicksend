# frozen_string_literal: true

RSpec.describe Clicksend::RetryPolicy do
  subject(:policy) { described_class.new(max_retries: 2, base_delay: 1.0, max_delay: 3.0, random: fixed_random) }

  let(:fixed_random) { Struct.new(:value) { def rand = value }.new(0.5) }

  def rate_limited(retry_after = nil)
    Clicksend::RateLimitError.new(http_status: 429, headers: retry_after ? {"retry-after" => retry_after.to_s} : {})
  end

  let(:server_error) { Clicksend::ServerError.new(http_status: 503) }
  let(:read_timeout) { Clicksend::TimeoutError.new("read") }
  let(:refused) { Clicksend::ConnectionError.new("refused", request_sent: false) }
  let(:reset) { Clicksend::ConnectionError.new("reset") }

  describe "what is retried" do
    {
      "429 on a non-idempotent request" => [:rate_limited, false, true],
      "429 on an idempotent request" => [:rate_limited, true, true],
      "a refused connection on a non-idempotent request" => [:refused, false, true],
      "a read timeout on an idempotent request" => [:read_timeout, true, true],
      "a read timeout on a non-idempotent request" => [:read_timeout, false, false],
      "a reset connection on a non-idempotent request" => [:reset, false, false],
      "a 5xx on an idempotent request" => [:server_error, true, true],
      "a 5xx on a non-idempotent request" => [:server_error, false, false]
    }.each do |description, (error_name, idempotent, retried)|
      it "#{retried ? "retries" : "does not retry"} #{description}" do
        error = (error_name == :rate_limited) ? rate_limited : public_send(error_name)
        delay = policy.delay(error: error, attempt: 0, idempotent: idempotent)
        retried ? expect(delay).to(be_a(Numeric)) : expect(delay).to(be_nil)
      end
    end

    it "never retries client errors or malformed responses" do
      [Clicksend::BadRequestError.new(http_status: 400), Clicksend::AuthenticationError.new(http_status: 401),
        Clicksend::MalformedResponseError.new("bad")].each do |error|
        expect(policy.delay(error: error, attempt: 0, idempotent: true)).to be_nil
      end
    end

    it "gives up after max_retries" do
      expect(policy.delay(error: server_error, attempt: 1, idempotent: true)).not_to be_nil
      expect(policy.delay(error: server_error, attempt: 2, idempotent: true)).to be_nil
    end

    it "retries nothing when max_retries is 0" do
      expect(described_class.new(max_retries: 0).delay(error: rate_limited, attempt: 0, idempotent: true)).to be_nil
    end
  end

  describe "how long it waits" do
    it "backs off exponentially with jitter, capped at max_delay" do
      delays = (0..3).map { |attempt| described_class.new(max_retries: 9, base_delay: 1.0, max_delay: 3.0, random: fixed_random).delay(error: server_error, attempt: attempt, idempotent: true) }
      expect(delays).to eq([0.75, 1.5, 2.25, 2.25])
    end

    it "honours Retry-After" do
      expect(policy.delay(error: rate_limited(4), attempt: 0, idempotent: false)).to eq(4)
    end

    it "gives up instead of waiting longer than max_retry_after" do
      expect(policy.delay(error: rate_limited(120), attempt: 0, idempotent: false)).to be_nil
    end

    it "falls back to backoff when Retry-After is absent" do
      expect(policy.delay(error: rate_limited, attempt: 0, idempotent: false)).to eq(0.75)
    end
  end
end
