# frozen_string_literal: true

module Clicksend
  module Testing
    # One FakeAPI#fail_next instruction: what fails, which requests it
    # applies to, and whether ClickSend processed the request first.
    # @api private
    class Failure
      # outcome => [error class, request_sent, message]
      CONNECTION = {
        connection_refused: [ConnectionError, false, "Connection refused"],
        open_timeout: [TimeoutError, false, "Timed out opening the connection"],
        timeout: [TimeoutError, nil, "Timed out waiting for the response"],
        connection_reset: [ConnectionError, nil, "Connection reset by peer"]
      }.freeze
      OUTCOMES = (CONNECTION.keys + [:interrupted]).freeze

      attr_reader :times

      def initialize(outcome, status:, processed:, retry_after:, path:, method:, times:)
        label = outcome ? outcome.inspect : "status: #{status.inspect}"
        if outcome.nil? == status.nil?
          raise ArgumentError, "fail_next needs an outcome (#{OUTCOMES.map(&:inspect).join(", ")}) or status:, not both"
        end
        raise ArgumentError, "retry_after: only applies to status: 429" if retry_after && status != 429

        if outcome == :interrupted
          # The worker is stopped mid-send: whether ClickSend got the request
          # first is exactly what the application can't know.
          @interrupted = true
          ambiguous = true
        elsif outcome
          @error_class, @request_sent, @message = CONNECTION.fetch(outcome) do
            raise ArgumentError, "unknown fail_next outcome #{outcome.inspect}; use one of #{OUTCOMES.map(&:inspect).join(", ")} or status:"
          end
          ambiguous = @request_sent.nil?
        else
          raise ArgumentError, "status must be an Integer HTTP error status (400..599), got #{status.inspect}" unless status.is_a?(Integer) && (400..599).cover?(status)
          if !retry_after.nil? && !(retry_after.is_a?(Integer) && retry_after >= 0)
            raise ArgumentError, "retry_after must be a non-negative Integer (seconds)"
          end
          @status = status
          @retry_after = retry_after || 0
          ambiguous = status >= 500
        end

        if ambiguous && ![true, false].include?(processed)
          raise ArgumentError, "fail_next(#{label}) needs processed: true or false: did ClickSend act on the request before the failure?"
        elsif !ambiguous && !processed.nil?
          raise ArgumentError, "processed: does not apply to fail_next(#{label}): such a request is never processed"
        end
        raise ArgumentError, "path must be a String such as \"/v3/sms/send\"" if !path.nil? && !(path.is_a?(String) && path.start_with?("/"))
        unless method.nil? || Connection::HTTP_METHODS.include?(method.to_s.downcase.to_sym)
          raise ArgumentError, "method must be one of #{Connection::HTTP_METHODS.join(", ")}"
        end
        raise ArgumentError, "times must be a positive Integer" unless times.is_a?(Integer) && times.positive?

        @processed = processed == true
        @path = path
        @method = method&.to_s&.downcase&.to_sym
        @times = times
        freeze
      end

      # Whether ClickSend acts on the request before the failure.
      def processed?
        @processed
      end

      def matches?(request)
        (@path.nil? || @path == request.path) && (@method.nil? || @method == request.http_method)
      end

      # Raises the connection error or the SimulatedInterrupt, or returns the
      # error response.
      # @return [Clicksend::Transport::Response]
      def trigger
        if @interrupted
          raise SimulatedInterrupt, "Worker interrupted mid-request, #{@processed ? "after" : "before"} ClickSend processed it " \
            "(simulated by Clicksend::Testing::FakeAPI#fail_next(:interrupted); this models the job runner, not ClickSend)"
        end
        raise @error_class.new("#{@message} (simulated by Clicksend::Testing::FakeAPI)", request_sent: @request_sent) if @error_class
        return Payloads.error(@status) unless @status == 429

        Payloads.error(429, nil, nil, {
          "retry-after" => @retry_after.to_s, "x-ratelimit-limit" => "20", "x-ratelimit-remaining" => "0",
          "ratelimit-reset" => @retry_after.to_s
        })
      end
    end
  end
end
