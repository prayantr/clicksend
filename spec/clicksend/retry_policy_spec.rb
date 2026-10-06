# frozen_string_literal: true

# RetryPolicy only times retries and enforces the budget. Which failures may
# be retried at all is decided by the connection (spec/clicksend/connection_spec.rb,
# "retry safety"), so these examples only use failures that are safe to retry.
RSpec.describe Clicksend::RetryPolicy do
  subject(:policy) { described_class.new(max_retries: 2, base_delay: 1.0, max_delay: 3.0, random: fixed_random) }

  let(:fixed_random) { Struct.new(:value) { def rand = value }.new(0.5) }
  let(:server_error) { Clicksend::ServerError.new(http_status: 503) }

  def rate_limited(retry_after = nil)
    Clicksend::RateLimitError.new(http_status: 429, headers: retry_after ? {"retry-after" => retry_after.to_s} : {})
  end

  describe "the retry budget" do
    it "gives up after max_retries" do
      expect(policy.delay(error: server_error, attempt: 1)).not_to be_nil
      expect(policy.delay(error: server_error, attempt: 2)).to be_nil
    end

    it "retries nothing when max_retries is 0" do
      expect(described_class.new(max_retries: 0).delay(error: rate_limited, attempt: 0)).to be_nil
    end

    it "still accepts the idempotent: keyword it took in 1.0" do
      expect(policy.delay(error: server_error, attempt: 0, idempotent: false)).to eq(0.75)
    end
  end

  describe "how long it waits" do
    it "backs off exponentially with jitter, capped at max_delay" do
      long = described_class.new(max_retries: 9, base_delay: 1.0, max_delay: 3.0, random: fixed_random)
      expect((0..3).map { |attempt| long.delay(error: server_error, attempt: attempt) }).to eq([0.75, 1.5, 2.25, 2.25])
    end

    it "honours Retry-After" do
      expect(policy.delay(error: rate_limited(4), attempt: 0)).to eq(4)
    end

    it "gives up instead of waiting longer than max_retry_after" do
      expect(policy.delay(error: rate_limited(120), attempt: 0)).to be_nil
      expect(described_class.new(max_retry_after: 200).delay(error: rate_limited(120), attempt: 0)).to eq(120)
    end

    it "falls back to backoff when Retry-After is absent" do
      expect(policy.delay(error: rate_limited, attempt: 0)).to eq(0.75)
    end

    it "uses real randomness by default, within the jitter band" do
      delay = described_class.new(base_delay: 1.0).delay(error: server_error, attempt: 0)
      expect(delay).to be_between(0.5, 1.0)
    end
  end

  describe "configuration" do
    it "rejects invalid settings" do
      expect { described_class.new(max_retries: -1) }.to raise_error(Clicksend::ConfigurationError, /max_retries/)
      expect { described_class.new(max_retries: 1.5) }.to raise_error(Clicksend::ConfigurationError, /max_retries/)
      expect { described_class.new(base_delay: -1) }.to raise_error(Clicksend::ConfigurationError, /base_delay/)
      expect { described_class.new(max_delay: "8") }.to raise_error(Clicksend::ConfigurationError, /max_delay/)
      expect { described_class.new(max_retry_after: nil) }.to raise_error(Clicksend::ConfigurationError, /max_retry_after/)
    end

    it "is frozen, so one policy can be shared by clients on many threads" do
      expect(policy).to be_frozen
      expect(policy.inspect).to eq("#<Clicksend::RetryPolicy max_retries=2 base_delay=1.0 max_delay=3.0 max_retry_after=30>")
    end
  end
end
