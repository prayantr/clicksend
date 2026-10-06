# frozen_string_literal: true

module Clicksend
  # A successful (2xx) ClickSend API response, as returned by Client#request.
  #
  # +body+ is the parsed JSON (deep-frozen), or nil for an empty body. Most
  # ClickSend v3 endpoints wrap their payload in an envelope:
  #
  #   {"http_code": 200, "response_code": "SUCCESS", "response_msg": "...", "data": {...}}
  #
  # The envelope readers return nil when the body doesn't follow that shape.
  # +request+ (a Clicksend::RequestInfo) says which call this was and how many
  # attempts it took.
  Response = Data.define(:http_status, :headers, :body, :request) do
    def initialize(http_status:, headers:, body:, request: nil)
      super
    end

    # The envelope's +data+ member.
    def data
      envelope("data")
    end

    # The envelope's +response_code+, e.g. "SUCCESS".
    def response_code
      envelope("response_code")
    end

    # The envelope's human-readable +response_msg+.
    def response_msg
      envelope("response_msg")
    end

    # Rate-limit headers sent with this response, if any. See Clicksend::RateLimit.
    # @return [Clicksend::RateLimit, nil]
    def rate_limit
      RateLimit.from_headers(headers)
    end

    def inspect
      "#<#{self.class.name} http_status=#{http_status} response_code=#{response_code.inspect}>"
    end

    private

    def envelope(key)
      body[key] if body.is_a?(Hash)
    end
  end
end
