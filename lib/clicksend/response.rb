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
  #
  # #request (a Clicksend::RequestInfo) says which call this was and how many
  # attempts it took. It is deliberately not a Data member, so equality,
  # +to_h+ and pattern matching (+in [status, headers, body]+,
  # +in {http_status:}+) behave exactly as in 1.0.
  Response = Data.define(:http_status, :headers, :body) do
    def initialize(http_status:, headers:, body:, request: nil)
      @request = request
      super(http_status: http_status, headers: headers, body: body)
    end

    # @return [Clicksend::RequestInfo, nil]
    attr_reader :request

    # Like Data#with, keeping #request unless a new one is given.
    def with(**changes)
      super(request: request, **changes)
    end

    # Marshal (e.g. Rails.cache) must rebuild the object through #initialize:
    # a frozen Data instance can't receive #request afterwards.
    def _dump(_level)
      Marshal.dump([to_h, request])
    end

    def self._load(data)
      members, request = Marshal.load(data) # rubocop:disable Security/MarshalLoad
      new(**members, request: request)
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
