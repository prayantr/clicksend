# frozen_string_literal: true

module Clicksend
  # Rate-limit counters ClickSend sent with a response, as exposed by
  # Response#rate_limit and APIError#rate_limit.
  #
  # ClickSend does not document its rate limits or these headers. They were
  # observed on GET /v3/account (2026-10-05): +x-ratelimit-limit+,
  # +x-ratelimit-remaining+ and +ratelimit-reset+ (seconds until the window
  # resets). Treat every field as advisory and possibly nil; nil overall means
  # none of the headers were present.
  #
  # +reset_at+ is computed when the response is read: now + +reset_in+.
  RateLimit = Data.define(:limit, :remaining, :reset_in, :reset_at)

  class RateLimit
    HEADERS = {
      limit: "x-ratelimit-limit",
      remaining: "x-ratelimit-remaining",
      reset_in: "ratelimit-reset"
    }.freeze

    # @param headers [Hash] lower-cased response headers
    # @return [Clicksend::RateLimit, nil]
    def self.from_headers(headers, now: Time.now)
      return unless headers.is_a?(Hash)

      values = HEADERS.transform_values { |name| non_negative_integer(headers[name]) }
      return if values.values.all?(&:nil?)

      new(**values, reset_at: values[:reset_in]&.then { |seconds| now + seconds })
    end

    def self.non_negative_integer(value)
      number = Integer(value.to_s.strip, 10, exception: false) if value
      number if number && number >= 0
    end
    private_class_method :non_negative_integer
  end
end
