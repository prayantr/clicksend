# frozen_string_literal: true

module Clicksend
  # Decides whether a failed attempt may be retried, and after how long.
  #
  # ClickSend's send endpoints accept no idempotency key, so retrying a send
  # that may already have reached ClickSend could deliver the message twice.
  # The rules are therefore:
  #
  # * 429 Too Many Requests: ClickSend did not process the request, so it is
  #   retried for every method, honouring Retry-After (up to +max_retry_after+).
  # * Connection failures known to happen before the request was sent
  #   (refused, DNS, connect timeout): retried for every method.
  # * Read timeouts, resets and 5xx responses: retried only when the request
  #   is idempotent. By default only GET requests are.
  class RetryPolicy
    attr_reader :max_retries

    def initialize(max_retries: 2, base_delay: 0.5, max_delay: 8.0, max_retry_after: 30, random: Random)
      @max_retries = max_retries
      @base_delay = base_delay
      @max_delay = max_delay
      @max_retry_after = max_retry_after
      @random = random
    end

    # @param error [Clicksend::Error] the failure of attempt number +attempt+ (0-based)
    # @return [Numeric, nil] seconds to wait before retrying, or nil to give up
    def delay(error:, attempt:, idempotent:)
      return if attempt >= max_retries

      case error
      when RateLimitError
        rate_limit_delay(error, attempt)
      when ServerError
        backoff(attempt) if idempotent
      when ConnectionError
        backoff(attempt) if idempotent || !error.request_may_have_been_sent?
      end
    end

    private

    def rate_limit_delay(error, attempt)
      wait = error.retry_after
      return backoff(attempt) if wait.nil?

      # Rather than block a web request or job for minutes, surface the
      # RateLimitError and let the caller decide.
      wait if wait <= @max_retry_after
    end

    # Exponential backoff with "equal jitter": half fixed, half random.
    def backoff(attempt)
      ceiling = [@base_delay * (2**attempt), @max_delay].min
      (ceiling / 2.0) + (@random.rand * ceiling / 2.0)
    end
  end
end
