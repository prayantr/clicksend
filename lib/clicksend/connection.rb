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

    # What code outside the gem (a logger, an instrumenter, a retry policy, a
    # custom transport) raises when it has a bug: StandardError, and also
    # ScriptError (NotImplementedError from an abstract method, LoadError from
    # a lazily required exporter). Such a failure must never escape as a
    # non-Clicksend error after a send was accepted: job runners such as
    # Sidekiq rescue Exception and would run the job, and the send, again.
    # Interrupt, SystemExit and NoMemoryError still propagate.
    FOREIGN_FAILURES = [StandardError, ScriptError].freeze

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

    # The longest delay (seconds, about 68 years) Kernel.sleep accepts on
    # every platform. A policy delay beyond it can't be waited for (sleep
    # raises RangeError), so it means "don't retry".
    MAX_SLEEP = (2**31) - 1

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
      instrumented(call) { |payload| run(call, query, body, headers, payload) }
    end

    # Never show the Authorization header.
    def inspect
      "#<#{self.class.name}>"
    end

    private

    # Runs the call inside the instrumenter's request.clicksend block, but
    # never lets the instrumenter change the outcome: once the block has run,
    # whatever the instrumenter raises (a failing subscriber, a frozen
    # payload, ...) is logged and the call's own result or error wins. Without
    # this, a metrics outage after an accepted send would surface as a
    # non-Clicksend error that a job runner retries: a duplicate SMS.
    #
    # +state+ moves :pending -> :running -> :done, under a lock because an
    # instrumenter may run the block on another thread. What it is when
    # #instrument returns or raises decides the outcome:
    #
    # [:done]    the call's result or error. Any other exception can only be
    #            the instrumenter's, and only then is it ignored.
    # [:pending] nothing was sent. The block becomes :abandoned, so an
    #            instrumenter that kept it and calls it later gets a
    #            ConfigurationError instead of sending.
    # [:running] the block was left unfinished. An exception that escaped the
    #            request itself is a genuine bug and propagates: #run turns
    #            every failure it can foresee into a Clicksend::Error, and
    #            hiding one once made #request return nil after an accepted
    #            send. Otherwise the block is still running on another thread
    #            (or the instrumenter swallowed what it raised), so the
    #            request may be or may yet be sent: a ConfigurationError,
    #            ambiguous unless the request is idempotent.
    #
    # A second call of the block raises instead of sending again.
    def instrumented(call)
      payload = {http_method: call[:method], path: reported_path(call[:path]), operation: call[:operation], idempotent: call[:idempotent]}
      lock = Mutex.new
      state = :pending
      outcome = escaped = failure = nil
      begin
        @instrumenter.instrument("request.clicksend", payload) do
          lock.synchronize do
            raise ConfigurationError, "the instrumenter ran the request block after #instrument returned; it must yield before returning" if state == :abandoned
            raise ConfigurationError, "the instrumenter ran the request block twice; #instrument must yield once" unless state == :pending

            state = :running
          end
          result = begin
            yield payload
          rescue Error => e
            e
          rescue Exception => e # rubocop:disable Lint/RescueException
            lock.synchronize { escaped = e }
            raise
          end
          lock.synchronize { outcome, state = result, :done }
          # Raise inside the block so ActiveSupport records the exception.
          result.is_a?(Error) ? raise(result) : result
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        failure = e
      end
      final, escaped = lock.synchronize { [(state == :pending) ? (state = :abandoned) : state, escaped] }

      case final
      when :abandoned
        raise failure if failure # the instrumenter failed before the request: nothing was sent

        raise ConfigurationError, "the instrumenter did not run the request: #instrument must yield"
      when :running
        raise failure if failure&.equal?(escaped)

        error = ConfigurationError.new("the instrumenter returned before the request finished; #instrument must run the block to completion before returning")
        error.mark_ambiguous! unless call[:idempotent]
        raise error, cause: failure
      end
      if failure && !failure.equal?(outcome)
        raise failure unless FOREIGN_FAILURES.any? { |kind| failure.is_a?(kind) }

        log(:warn) { "instrumenter raised #{failure.class.name} for #{call[:method].upcase} #{reported_path(call[:path])}; ignored" }
      end
      raise outcome if outcome.is_a?(Error)

      outcome
    end

    def run(call, query, body, headers, payload)
      attempt = 0
      loop do
        info = RequestInfo.new(http_method: call[:method], path: reported_path(call[:path]), operation: call[:operation],
          idempotent: call[:idempotent], attempts: attempt + 1)
        outcome, kind = attempt_request(call, query, body, headers)
        if outcome.is_a?(Response)
          record(payload, attempts: info.attempts, http_status: outcome.http_status, response_code: outcome.response_code, ambiguous: false)
          return outcome.with(request: info)
        end

        error = outcome
        error.request = info
        delay = retry_delay(error, kind, attempt, call[:idempotent])
        unless delay
          error.mark_ambiguous! if !call[:idempotent] && MAY_HAVE_BEEN_PROCESSED.include?(kind)
          record(payload, attempts: info.attempts, http_status: error_status(error), response_code: error_code(error), ambiguous: error.ambiguous?)
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
    #
    # Errors raised by the transport are copied before the connection adds
    # context, so a frozen or reused exception instance is never modified.
    # Anything a custom transport raises that is not a Clicksend::Error is
    # treated as a connection failure that may have been sent.
    def attempt_request(call, query, body, headers)
      started = monotonic_now
      raw = begin
        @transport.call(call[:method], call[:path], query: query, body: body, headers: headers)
      rescue ConnectionError => e
        return [e.dup, e.request_may_have_been_sent? ? :unknown : :not_sent]
      rescue MalformedResponseError => e
        return [e.dup, :undocumented]
      rescue Error => e
        return [e.dup, :unknown] # any other Clicksend error from a custom transport: outcome unknown
      rescue *FOREIGN_FAILURES => e
        return [wrap_failure(ConnectionError, "The transport failed", e), :unknown]
      end
      log(:info) { "#{call[:method].upcase} #{reported_path(call[:path])} -> #{raw.status} (#{elapsed_ms(started)}ms)" }
      begin
        interpret(raw)
      rescue MalformedResponseError => e
        [e, :undocumented]
      rescue *FOREIGN_FAILURES => e
        # A response this gem cannot even read (e.g. a custom transport's
        # body that is not a String) is undocumented: ambiguous for a send.
        [wrap_failure(MalformedResponseError, "Could not read ClickSend's response", e), :undocumented]
      end
    end

    # Raised (and rescued) inside the caller's rescue, so #cause is the
    # original exception. Only its class is copied into the message: a
    # foreign exception's message may hold a URL, a query string or a body.
    def wrap_failure(error_class, text, error)
      raise error_class, "#{text}: #{error.class.name}"
    rescue error_class => e
      e
    end

    # @return [Response, Array(Error, Symbol)]
    def interpret(raw)
      unless raw.respond_to?(:status) && raw.status.is_a?(Integer) && raw.status.between?(100, 599)
        raise MalformedResponseError, "The transport returned no valid HTTP status"
      end

      body = parse_body(raw)
      status = effective_status(raw.status, body)
      return Response.new(http_status: raw.status, headers: raw.headers, body: body) if success?(status)

      error = api_error(status, raw, body)
      # An error reported only inside a 2xx body is undocumented for v3, so
      # nothing is known about whether ClickSend acted on the request.
      kind = if status != raw.status then :undocumented
      elsif status == 429 then :rate_limited
      elsif status >= 500 then :unknown
      elsif status >= 400 then :rejected
      else :undocumented # 1xx/3xx: not expected from ClickSend (redirects are not followed)
      end
      [error, kind]
    end

    # The safety rule, then the policy's timing and budget.
    #
    # The connection also enforces the policy's own max_retries, so a policy
    # whose #delay never says no still cannot loop forever.
    def retry_delay(error, kind, attempt, idempotent)
      eligible = RETRY_ALWAYS.include?(kind) || (kind == :unknown && idempotent)
      return unless eligible

      budget = @retry_policy.max_retries
      return unless budget.is_a?(Integer) && attempt < budget

      delay = @retry_policy.delay(error: error, attempt: attempt)
      return if (delay.is_a?(Integer) || delay.is_a?(Rational)) && delay > MAX_SLEEP # Float() would warn

      delay = Float(delay) if delay.is_a?(Numeric)
      delay if delay.is_a?(Float) && delay.between?(0, MAX_SLEEP)
    rescue *FOREIGN_FAILURES => e
      # A broken policy stops retrying (the safe direction) and keeps the
      # request's own error.
      log(:warn) { "retry policy raised #{e.class.name}; not retrying" }
      nil
    end

    def announce_retry(call, error, attempt, delay)
      log(:warn) do
        "#{call[:method].upcase} #{reported_path(call[:path])} failed (#{error.class.name}), retrying in #{format("%.2f", delay)}s " \
          "(retry #{attempt} of #{@retry_policy.max_retries})"
      end
      payload = {http_method: call[:method], path: reported_path(call[:path]), operation: call[:operation], attempt: attempt,
                 delay: delay, error_class: error.class.name, http_status: error_status(error)}
      @instrumenter.instrument("retry.clicksend", payload) {}
    rescue *FOREIGN_FAILURES => e
      log(:warn) { "instrumenter raised #{e.class.name} for retry.clicksend; ignored" }
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
    #
    # A body that isn't valid in its declared charset (JSON converts it to
    # UTF-8 first) is unreadable in the same way, so the status still decides:
    # a garbled 429 or 503 must stay retryable, and a 400 a rejection.
    def parse_body(raw)
      return nil if raw.body.b.strip.empty?

      JSON.parse(raw.body, freeze: true)
    rescue JSON::ParserError, EncodingError
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

    # Adds the outcome to the request.clicksend payload. The payload belongs
    # to the instrumenter's subscribers too; if one froze or replaced it,
    # the outcome is simply not recorded.
    def record(payload, **outcome)
      payload.update(outcome)
    rescue *FOREIGN_FAILURES
      nil
    end

    # A failing logger must not turn a completed request into an error.
    def log(level)
      @logger&.public_send(level, "[clicksend] #{yield}")
    rescue *FOREIGN_FAILURES
      nil
    end

    # The path as reported in errors, logs and instrumentation: never with a
    # query string or fragment, even if one was written into the path.
    def reported_path(path)
      path.split(/[?#]/, 2).first
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started)
      ((monotonic_now - started) * 1000).round
    end
  end
end
