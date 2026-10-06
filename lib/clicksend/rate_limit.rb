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
  # *Experimental*: because the headers are undocumented, this may change in
  # a minor release if ClickSend changes them.
  RateLimit = Data.define(:limit, :remaining, :reset_in)

  class RateLimit
    HEADERS = {
      limit: "x-ratelimit-limit",
      remaining: "x-ratelimit-remaining",
      reset_in: "ratelimit-reset"
    }.freeze

    # @api private Use Response#rate_limit or APIError#rate_limit.
    # @param headers [Hash] lower-cased response headers
    # @return [Clicksend::RateLimit, nil]
    def self.from_headers(headers)
      return unless headers.is_a?(Hash)

      values = HEADERS.transform_values { |name| non_negative_integer(headers[name]) }
      new(**values) unless values.values.all?(&:nil?)
    end

    def self.non_negative_integer(value)
      text = value.to_s.strip
      Integer(text, 10) if text.match?(/\A\d{1,9}\z/)
    end
    private_class_method :non_negative_integer
  end
end
