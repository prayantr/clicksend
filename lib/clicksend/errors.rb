# frozen_string_literal: true

require "time"

module Clicksend
  # Base class for every error raised by this gem.
  class Error < StandardError; end

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

  # 429: rate limited. ClickSend did not process the request.
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
  end

  # 5xx responses.
  class ServerError < APIError; end

  # A single message sent with Clicksend::Resources::SMS#deliver was not
  # accepted (its per-message status was not "SUCCESS"), even though the HTTP
  # request itself succeeded. Batch sends never raise this; inspect
  # Clicksend::SMS::Batch#rejected instead.
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
