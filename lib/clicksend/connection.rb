# frozen_string_literal: true

require "json"

module Clicksend
  # Runs one logical API call over a transport: encodes the JSON body, parses
  # the response envelope, maps failures to Clicksend errors, retries when the
  # retry policy says it is safe, and logs a one-line summary per attempt.
  #
  # Internal: use Client#request instead.
  class Connection
    HTTP_METHODS = %i[get post put patch delete].freeze

    ERROR_CLASSES = {
      400 => BadRequestError,
      401 => AuthenticationError,
      403 => ForbiddenError,
      404 => NotFoundError,
      429 => RateLimitError
    }.freeze

    def initialize(transport:, retry_policy:, logger: nil)
      @transport = transport
      @retry_policy = retry_policy
      @logger = logger
    end

    # @return [Clicksend::Response]
    # @raise [Clicksend::Error]
    def request(method, path, query: nil, body: nil, idempotent: false)
      headers = {}
      unless body.nil?
        headers["Content-Type"] = "application/json"
        body = JSON.generate(body)
      end

      attempt = 0
      begin
        started = monotonic_now
        raw = @transport.call(method, path, query: query, body: body, headers: headers)
        log(:info) { "#{method.upcase} #{path} -> #{raw.status} (#{elapsed_ms(started)}ms)" }
        build_response(raw)
      rescue ConnectionError, APIError => e
        delay = @retry_policy.delay(error: e, attempt: attempt, idempotent: idempotent)
        raise unless delay

        attempt += 1
        log(:warn) do
          "#{method.upcase} #{path} failed (#{e.class.name}), retrying in #{format("%.2f", delay)}s " \
            "(retry #{attempt} of #{@retry_policy.max_retries})"
        end
        Kernel.sleep(delay)
        retry
      end
    end

    private

    def build_response(raw)
      body = parse_body(raw)
      status = effective_status(raw.status, body)
      return Response.new(status: raw.status, headers: raw.headers, body: body) if success?(status)

      envelope = body.is_a?(Hash) ? body : {}
      error_class = ERROR_CLASSES.fetch(status) do
        if status >= 500 then ServerError
        elsif status >= 400 then ClientError
        else APIError
        end
      end
      raise error_class.new(
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
