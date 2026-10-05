# frozen_string_literal: true

require "json"

module Clicksend
  # Runs one logical API call over a transport: encodes the JSON body, parses
  # the response envelope, maps failures to Clicksend errors, retries when the
  # retry policy says it is safe, and logs a one-line summary per attempt.
  #
  # @api private Use Client#request instead.
  class Connection
    HTTP_METHODS = %i[get post put patch delete].freeze

    ERROR_CLASSES = {
      400 => BadRequestError,
      401 => AuthenticationError,
      403 => ForbiddenError,
      404 => NotFoundError,
      429 => RateLimitError
    }.freeze

    # @param headers [Hash] sent with every request (authentication, User-Agent)
    def initialize(transport:, retry_policy:, headers: {}, logger: nil)
      @transport = transport
      @retry_policy = retry_policy
      @headers = headers.dup.freeze
      @logger = logger
    end

    # @return [Clicksend::Response]
    # @raise [Clicksend::Error]
    def request(method, path, query: nil, body: nil, idempotent: false)
      headers = @headers
      unless body.nil?
        headers = headers.merge("Content-Type" => "application/json")
        body = JSON.generate(body)
      end

      attempt = 0
      loop do
        outcome, retry_allowed = attempt_request(method, path, query, body, headers)
        return outcome if outcome.is_a?(Response)

        error = outcome
        delay = retry_allowed && @retry_policy.delay(error: error, attempt: attempt, idempotent: idempotent)
        raise error unless delay

        attempt += 1
        log(:warn) do
          "#{method.upcase} #{path} failed (#{error.class.name}), retrying in #{format("%.2f", delay)}s " \
            "(retry #{attempt} of #{@retry_policy.max_retries})"
        end
        Kernel.sleep(delay)
      end
    end

    # Never show the Authorization header.
    def inspect
      "#<#{self.class.name}>"
    end

    private

    # One HTTP attempt. Returns a Response, or [error, retry_allowed]. Errors
    # are returned rather than raised so the retry decision can use facts
    # about this attempt without storing state on the (shared) Connection.
    def attempt_request(method, path, query, body, headers)
      started = monotonic_now
      raw = @transport.call(method, path, query: query, body: body, headers: headers)
      log(:info) { "#{method.upcase} #{path} -> #{raw.status} (#{elapsed_ms(started)}ms)" }
      interpret(raw)
    rescue ConnectionError => e
      [e, true]
    end

    # @return [Response, Array(APIError, Boolean)]
    def interpret(raw)
      body = parse_body(raw)
      status = effective_status(raw.status, body)
      return Response.new(http_status: raw.status, headers: raw.headers, body: body) if success?(status)

      # An error reported only inside a 2xx body is undocumented for v3, so
      # nothing is known about whether ClickSend acted on the request: never
      # retry it, whatever the reported code.
      [api_error(status, raw, body), status == raw.status]
    end

    def api_error(status, raw, body)
      envelope = body.is_a?(Hash) ? body : {}
      error_class = ERROR_CLASSES.fetch(status) do
        if status >= 500 then ServerError
        elsif status >= 400 then ClientError
        else APIError
        end
      end
      error_class.new(
        http_status: status,
        response_code: string_or_nil(envelope["response_code"]),
        response_msg: string_or_nil(envelope["response_msg"]),
        headers: raw.headers,
        body: body
      )
    end

    # Returns the parsed JSON, nil for an empty body, or the raw String when an
    # error response isn't JSON (e.g. an HTML page from a proxy).
    def parse_body(raw)
      return nil if raw.body.strip.empty?

      JSON.parse(raw.body, freeze: true)
    rescue JSON::ParserError
      return raw.body unless success?(raw.status)

      raise MalformedResponseError.new(
        "ClickSend returned a non-JSON body with HTTP #{raw.status}",
        http_status: raw.status, body: raw.body[0, 500]
      )
    end

    # ClickSend repeats the status inside the envelope as +http_code+. If a 2xx
    # response carries an error http_code, treat the call as failed rather than
    # silently returning an error payload. (Observed on the legacy host; not
    # documented for v3, so this is defensive.)
    def effective_status(status, body)
      envelope_code = body["http_code"] if body.is_a?(Hash)
      if success?(status) && envelope_code.is_a?(Integer) && envelope_code >= 400
        envelope_code
      else
        status
      end
    end

    def success?(status)
      (200..299).cover?(status)
    end

    def string_or_nil(value)
      value.is_a?(String) ? value : nil
    end

    def log(level)
      @logger&.public_send(level, "[clicksend] #{yield}")
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic_now - started) * 1000).round
    end
  end
end
