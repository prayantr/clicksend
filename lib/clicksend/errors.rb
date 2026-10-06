# frozen_string_literal: true

require "time"

module Clicksend
  # What a failed (or successful) API call was: available as Error#request and
  # Response#request. Safe to log: +path+ never includes the query string, and
  # nothing here holds credentials, headers or bodies.
  #
  # +method+ is a lower-case Symbol (:get, :post, ...); +operation+ names the
  # wrapped method that made the call (e.g. "sms.deliver"), or is whatever was
  # passed to Client#request (nil by default); +attempts+ counts HTTP attempts,
  # so it is 1 when nothing was retried.
  RequestInfo = Data.define(:method, :path, :operation, :idempotent, :attempts) do
    def to_s
      "#{method.to_s.upcase} #{path}"
    end

    def inspect
      "#<#{self.class.name} #{self} operation=#{operation.inspect} idempotent=#{idempotent} attempts=#{attempts}>"
    end
  end

  # Base class for every error raised by this gem.
  class Error < StandardError
    # @return [Clicksend::RequestInfo, nil] the API call that failed, when the
    #   error came from one
    attr_reader :request

    # @api private Set by the connection before the error is raised.
    attr_writer :request

    # Whether repeating the same request later is both safe (it cannot cause a
    # second side effect, such as a second SMS) and might succeed.
    #
    # True for a 429, for connection failures that never reached ClickSend,
    # and for connection failures and 5xx responses on idempotent requests.
    # False for everything else, and always false when #ambiguous?.
    def retryable?
      false
    end

    # True when a request that is not safe to repeat (such as an SMS send) may
    # or may not have been processed by ClickSend. Such errors are also
    # Clicksend::AmbiguousRequestError, so they can be rescued as one.
    def ambiguous?
      is_a?(AmbiguousRequestError)
    end

    # The message, followed by the request it came from, e.g.
    # "HTTP 500 (POST /v3/sms/send)".
    def to_s
      request ? "#{super} (#{request})" : super
    end
  end

  # Extended onto an error when a request that is not safe to repeat may have
  # been processed: a timeout or connection failure after the request may have
  # been written, a 5xx, an error reported inside a 2xx body, or a 2xx
  # response that could not be read. The error keeps its class, so
  #
  #   rescue Clicksend::AmbiguousRequestError => e
  #
  # catches every unknown-outcome failure, and existing rescues of
  # TimeoutError, ServerError, ... keep working.
  #
  # For an SMS send it means the message may or may not have been accepted.
  # The gem never retries it; see the README on reconciling with
  # Resources::SMS#history before sending again.
  module AmbiguousRequestError
    # Always true: ClickSend may have acted on the request.
    def request_may_have_been_processed?
      true
    end
  end

  # Missing or invalid client configuration (e.g. no API key).
  class ConfigurationError < Error; end

  # The HTTP exchange failed before a response was received (DNS, refused
  # connection, TLS failure, connection reset, ...).
  class ConnectionError < Error
    # @param request_sent [Boolean, nil] +false+ when the failure is known to
    #   have happened before the request reached ClickSend (so retrying cannot
    #   duplicate it); +true+/+nil+ when it may have been sent.
    def initialize(message = nil, request_sent: nil)
      super(message)
      @request_sent = request_sent
    end

    # Whether ClickSend may have received (and acted on) the request.
    def request_may_have_been_sent?
      @request_sent != false
    end

    def retryable?
      return false if ambiguous?

      !request_may_have_been_sent? || request&.idempotent == true
    end
  end

  # Opening the connection or reading the response took longer than the
  # configured timeout. For a send, the message may still have been delivered.
  class TimeoutError < ConnectionError; end

  # ClickSend answered with something this gem cannot interpret: invalid JSON,
  # or JSON that lacks the fields a wrapped endpoint documents.
  class MalformedResponseError < Error
    attr_reader :http_status, :body

    def initialize(message = nil, http_status: nil, body: nil)
      super(message)
      @http_status = http_status
      @body = body
    end
  end

  # ClickSend returned an error response. Subclasses map HTTP statuses.
  #
  # +response_code+ and +response_msg+ come from ClickSend's response envelope
  # (e.g. "INVALID_RECIPIENT", "Authorization failed.") when present.
  class APIError < Error
    attr_reader :http_status, :response_code, :response_msg, :headers, :body

    def initialize(message = nil, http_status: nil, response_code: nil, response_msg: nil, headers: {}, body: nil)
      super(message || default_message(http_status, response_code, response_msg))
      @http_status = http_status
      @response_code = response_code
      @response_msg = response_msg
      @headers = headers
      @body = body
    end

    # Rate-limit headers sent with this response, if any. See Clicksend::RateLimit.
    # @return [Clicksend::RateLimit, nil]
    def rate_limit
      RateLimit.from_headers(headers)
    end

    private

    def default_message(http_status, response_code, response_msg)
      detail = [response_code, response_msg].compact.join(" - ")
      detail.empty? ? "HTTP #{http_status}" : "HTTP #{http_status}: #{detail}"
    end
  end

  # 4xx responses.
  class ClientError < APIError; end

  # 400: the request was invalid (e.g. MISSING_REQUIRED_FIELDS).
  class BadRequestError < ClientError; end

  # 401: the username/API key pair was rejected.
  class AuthenticationError < ClientError; end

  # 403: the credentials are valid but not allowed to do this.
  class ForbiddenError < ClientError; end

  # 404: the resource does not exist.
  class NotFoundError < ClientError; end

  # 429: rate limited. ClickSend documents this as a request that "cannot be
  # served", so it is treated as not processed (an inference, not a documented
  # guarantee).
  class RateLimitError < ClientError
    # Seconds to wait before retrying, from the Retry-After header, if any.
    def retry_after
      value = headers["retry-after"]
      return if value.nil?

      Integer(value, exception: false)&.then { |seconds| [seconds, 0].max } ||
        begin
          [Time.httpdate(value) - Time.now, 0].max
        rescue ArgumentError
          nil
        end
    end

    def retryable?
      !ambiguous?
    end
  end

  # 5xx responses.
  class ServerError < APIError
    def retryable?
      !ambiguous? && request&.idempotent == true
    end
  end

  # A single message sent with Clicksend::Resources::SMS#deliver was not
  # accepted (its per-message status was not "SUCCESS"), even though the HTTP
  # request itself succeeded. Batch sends never raise this; inspect
  # Clicksend::SMS::Batch#rejected instead.
  #
  # Not #retryable?: ClickSend decided. (A "THROTTLED" status means an identical
  # message was sent to the same recipient moments ago.)
  class MessageRejected < Error
    # The Clicksend::SMS::Message describing the rejected message.
    attr_reader :result

    def initialize(result)
      @result = result
      super("ClickSend rejected the message: #{result.status}")
    end

    # ClickSend's per-message status, e.g. "INVALID_RECIPIENT".
    def status
      result.status
    end
  end
end
