# frozen_string_literal: true

require "json"

module Clicksend
  # Runs one logical API call over a transport: encodes the JSON body, parses
  # the response envelope, maps failures to Clicksend errors, retries when it
  # is safe, and reports each call to the logger and instrumenter.
  #
  # Whether a failure may be retried at all is decided here, from what is
  # known about the failure, and cannot be changed by configuration. The retry
  # policy only chooses the delay and enforces the retry budget.
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

    # How much is known about a failed attempt, which decides retries and
    # ambiguity:
    #
    # [:rate_limited] HTTP 429: not processed (ClickSend's documentation)
    # [:not_sent]     failed before the request was written
    # [:unknown]      may have been processed: read timeout, reset, TLS, 5xx
    # [:undocumented] an error inside a 2xx body, or an unreadable 2xx body
    # [:rejected]     any other 4xx: ClickSend refused the request
    RETRY_ALWAYS = %i[rate_limited not_sent].freeze
    MAY_HAVE_BEEN_PROCESSED = %i[unknown undocumented].freeze

    # @param headers [Hash] sent with every request (authentication, User-Agent)
    # @param instrumenter [#instrument] see Clicksend::Instrumentation
    def initialize(transport:, retry_policy:, headers: {}, logger: nil, instrumenter: Instrumentation::Null)
      @transport = transport
      @retry_policy = retry_policy
      @headers = headers.dup.freeze
      @logger = logger
      @instrumenter = instrumenter
    end

    # @return [Clicksend::Response]
    # @raise [Clicksend::Error]
    def request(method, path, query: nil, body: nil, idempotent: false, operation: nil)
      headers = @headers
      unless body.nil?
        headers = headers.merge("Content-Type" => "application/json")
        body = JSON.generate(body)
      end

      call = {method: method, path: path, operation: operation, idempotent: idempotent}
      @instrumenter.instrument("request.clicksend", call.dup) do |payload|
        run(call, query, body, headers, payload || {})
      end
    end

    # Never show the Authorization header.
    def inspect
      "#<#{self.class.name}>"
    end

    private

    def run(call, query, body, headers, payload)
      attempt = 0
      loop do
        info = RequestInfo.new(**call, attempts: attempt + 1)
        outcome, kind = attempt_request(call, query, body, headers)
        if outcome.is_a?(Response)
          payload.update(attempts: info.attempts, http_status: outcome.http_status, response_code: outcome.response_code, ambiguous: false)
          return outcome.with(request: info)
        end

        error = outcome
        error.request = info
        delay = retry_delay(error, kind, attempt, call[:idempotent])
        unless delay
          error.extend(AmbiguousRequestError) if !call[:idempotent] && MAY_HAVE_BEEN_PROCESSED.include?(kind)
          payload.update(attempts: info.attempts, http_status: error_status(error), response_code: error_code(error), ambiguous: error.ambiguous?)
          raise error
        end

        attempt += 1
        announce_retry(call, error, attempt, delay)
        Kernel.sleep(delay)
      end
    end

    # One HTTP attempt. Returns a Response, or [error, kind]. Errors are
    # returned rather than raised so the retry decision can use facts about
    # this attempt without storing state on the (shared) Connection.
    def attempt_request(call, query, body, headers)
      started = monotonic_now
      raw = @transport.call(call[:method], call[:path], query: query, body: body, headers: headers)
      log(:info) { "#{call[:method].upcase} #{call[:path]} -> #{raw.status} (#{elapsed_ms(started)}ms)" }
      interpret(raw)
    rescue ConnectionError => e
      [e, e.request_may_have_been_sent? ? :unknown : :not_sent]
    rescue MalformedResponseError => e
      [e, :undocumented]
    end

    # @return [Response, Array(Error, Symbol)]
    def interpret(raw)
      body = parse_body(raw)
      status = effective_status(raw.status, body)
      return Response.new(http_status: raw.status, headers: raw.headers, body: body) if success?(status)

      error = api_error(status, raw, body)
      # An error reported only inside a 2xx body is undocumented for v3, so
      # nothing is known about whether ClickSend acted on the request.
      kind = if status != raw.status then :undocumented
      elsif status == 429 then :rate_limited
      elsif status >= 500 then :unknown
      else :rejected
      end
      [error, kind]
    end

    # The safety rule, then the policy's timing and budget.
    def retry_delay(error, kind, attempt, idempotent)
      eligible = RETRY_ALWAYS.include?(kind) || (kind == :unknown && idempotent)
      return unless eligible

      delay = @retry_policy.delay(error: error, attempt: attempt)
      delay if delay.is_a?(Numeric) && delay.finite? && delay >= 0
    end

    def announce_retry(call, error, attempt, delay)
      log(:warn) do
        "#{call[:method].upcase} #{call[:path]} failed (#{error.class.name}), retrying in #{format("%.2f", delay)}s " \
          "(retry #{attempt} of #{@retry_policy.max_retries})"
      end
      @instrumenter.instrument(
        "retry.clicksend",
        call.slice(:method, :path, :operation).merge(attempt: attempt, delay: delay, error_class: error.class.name, http_status: error_status(error))
      )
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

    def error_status(error)
      error.http_status if error.respond_to?(:http_status)
    end

    def error_code(error)
      error.response_code if error.respond_to?(:response_code)
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
