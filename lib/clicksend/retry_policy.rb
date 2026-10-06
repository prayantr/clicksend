# frozen_string_literal: true

module Clicksend
  # Decides how long to wait before retrying, and whether the retry budget
  # allows another attempt. Pass one to Client.new(retry_policy:) to tune it:
  #
  #   Clicksend::Client.new(retry_policy: Clicksend::RetryPolicy.new(max_retries: 4, max_retry_after: 10))
  #
  # It does not decide *whether a failure is safe to retry*. That rule is
  # fixed in the connection, so no policy can make a send repeat after a
  # failure that may already have reached ClickSend:
  #
  # * 429 Too Many Requests: retried for every method (ClickSend documents it
  #   as a request that "cannot be served").
  # * Connection failures known to happen before the request was sent
  #   (refused, DNS, connect timeout): retried for every method.
  # * Read timeouts, resets, TLS errors and 5xx responses: retried only when
  #   the request is idempotent (GET, and mark-read calls with a cutoff).
  # * Anything else, including an error reported inside a 2xx body: never.
  #
  # Only for failures in the first three groups is #delay asked. Any object
  # with +max_retries+ and +delay(error:, attempt:)+ can stand in for this
  # class; it must be thread-safe, as one client is shared across threads.
  class RetryPolicy
    attr_reader :max_retries, :base_delay, :max_delay, :max_retry_after

    # @param max_retries [Integer] retries after the first attempt; 0 disables retrying
    # @param base_delay [Numeric] seconds; backoff ceiling for the first retry
    # @param max_delay [Numeric] seconds; the backoff ceiling never exceeds it
    # @param max_retry_after [Numeric] longest Retry-After (seconds) worth
    #   waiting for; a longer one is raised as RateLimitError instead of
    #   blocking the caller. Even with Float::INFINITY, a wait longer than
    #   Kernel.sleep accepts (2**31 - 1 seconds) is raised, not retried.
    def initialize(max_retries: 2, base_delay: 0.5, max_delay: 8.0, max_retry_after: 30, random: Random)
      unless max_retries.is_a?(Integer) && max_retries >= 0
        raise ConfigurationError, "max_retries must be a non-negative Integer"
      end
      {base_delay: base_delay, max_delay: max_delay, max_retry_after: max_retry_after}.each do |name, value|
        raise ConfigurationError, "#{name} must be a non-negative number of seconds" unless value.is_a?(Numeric) && value >= 0
      end

      @max_retries = max_retries
      @base_delay = base_delay
      @max_delay = max_delay
      @max_retry_after = max_retry_after
      @random = random
      freeze
    end

    # @param error [Clicksend::Error] the failure of attempt number +attempt+
    #   (0-based); already known to be safe to retry
    # @return [Numeric, nil] seconds to wait before retrying, or nil to give up.
    #   The connection also gives up on anything that is not a number of
    #   seconds between 0 and 2**31 - 1 (Kernel.sleep's limit).
    def delay(error:, attempt:, **)
      return if attempt >= max_retries
      return backoff(attempt) unless error.is_a?(RateLimitError)

      wait = error.retry_after
      return backoff(attempt) if wait.nil?

      # Rather than block a web request or job for minutes, surface the
      # RateLimitError and let the caller decide.
      wait if wait <= max_retry_after
    end

    def inspect
      "#<#{self.class.name} max_retries=#{max_retries} base_delay=#{base_delay} max_delay=#{max_delay} " \
        "max_retry_after=#{max_retry_after}>"
    end

    private

    # Exponential backoff with "equal jitter": half fixed, half random.
    def backoff(attempt)
      ceiling = [base_delay * (2**attempt), max_delay].min
      (ceiling / 2.0) + (@random.rand * ceiling / 2.0)
    end
  end
end
