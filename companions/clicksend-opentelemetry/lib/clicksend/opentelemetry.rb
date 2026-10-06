# frozen_string_literal: true

require "uri"
require "opentelemetry"
require "clicksend"
require_relative "opentelemetry/version"

module Clicksend
  # OpenTelemetry tracing for Clicksend::Client, built only on the client's
  # public instrumenter hook (see Clicksend::Instrumentation):
  #
  #   require "clicksend/opentelemetry"
  #
  #   CLICKSEND = Clicksend::Client.new(instrumenter: Clicksend::OpenTelemetry::Instrumenter.new)
  #
  # Each logical API call (retries included) becomes one span of kind CLIENT,
  # named after its operation ("clicksend sms.deliver"); each retry is a
  # "clicksend.retry" event on it. Spans never hold phone numbers, message
  # text, bodies, query strings, headers or credentials: only what the
  # request.clicksend payload holds, plus the server address.
  module OpenTelemetry
    # Spans for request.clicksend, span events for retry.clicksend.
    #
    # The instrumenter never changes a call's outcome. Its own failures are
    # sent to ::OpenTelemetry.handle_error, the request block runs exactly once
    # whatever happens, and the request's own result or exception is passed
    # through untouched. (Clicksend::Connection also ignores instrumenter
    # failures after the request has run; this class does not rely on that.)
    class Instrumenter
      SPAN_KEY = ::OpenTelemetry::Context.create_key("clicksend-span")
      private_constant :SPAN_KEY

      # @param tracer_provider [#tracer] defaults to the global provider (a
      #   proxy until the SDK is configured, so creating the client first is fine)
      # @param base_url [String] the client's base_url, for server.address and
      #   server.port (the instrumentation payload does not carry the host)
      # @param record_path [Boolean] whether to set url.path. Paths never hold
      #   query strings; some hold a message ID, and paths you pass to
      #   Client#request are reported as written.
      def initialize(tracer_provider: ::OpenTelemetry.tracer_provider, base_url: Clicksend::Client::DEFAULT_BASE_URL, record_path: true)
        @tracer = tracer_provider.tracer("clicksend-opentelemetry", VERSION)
        uri = URI.parse(base_url)
        @server = {"server.address" => uri.host, "server.port" => uri.port}.freeze
        @record_path = record_path
        freeze
      end

      # The Clicksend::Instrumentation interface.
      def instrument(name, payload = {}, &block)
        case name
        when "request.clicksend" then block ? trace(payload, &block) : nil
        when "retry.clicksend" then add_retry_event(payload, &block)
        else block&.call(payload)
        end
      end

      def inspect
        "#<#{self.class.name}>"
      end

      private

      def trace(payload)
        span = safely { @tracer.start_span(span_name(payload), kind: :client, attributes: start_attributes(payload)) }
        token = safely { attach(span) } if span
        begin
          result = yield payload
        rescue Exception => e # rubocop:disable Lint/RescueException
          safely { record_failure(span, e) } if span
          raise
        ensure
          safely { finish(span, token, payload) } if span
        end
        result
      end

      # Makes the span current, so HTTP-level spans (Faraday, Net::HTTP
      # instrumentation) nest under it and retry events can find it.
      def attach(span)
        ::OpenTelemetry::Context.attach(::OpenTelemetry::Trace.context_with_span(span).set_value(SPAN_KEY, span))
      end

      def finish(span, token, payload)
        ::OpenTelemetry::Context.detach(token) if token
        attributes = {
          "http.response.status_code" => payload[:http_status],
          "clicksend.response_code" => payload[:response_code],
          "clicksend.attempts" => payload[:attempts],
          "clicksend.ambiguous" => payload[:ambiguous]
        }.compact
        span.add_attributes(attributes) unless attributes.empty?
      ensure
        span.finish
      end

      # The exception's message is never recorded: an API error's message holds
      # ClickSend's response_msg, and a foreign exception's may hold anything.
      def record_failure(span, error)
        type = error.class.name || "Exception"
        span.set_attribute("error.type", type)
        span.add_event("exception", attributes: {
          "exception.type" => type,
          "exception.message" => safe_message(error),
          "exception.stacktrace" => Array(error.backtrace).join("\n")
        })
        span.status = ::OpenTelemetry::Trace::Status.error(type)
      end

      def add_retry_event(payload)
        safely do
          span = ::OpenTelemetry::Context.current.value(SPAN_KEY)
          span&.add_event("clicksend.retry", attributes: {
            "clicksend.retry.attempt" => payload[:attempt],
            "clicksend.retry.delay" => payload[:delay]&.to_f,
            "error.type" => payload[:error_class],
            "http.response.status_code" => payload[:http_status]
          }.compact)
        end
        yield payload if block_given?
      end

      def span_name(payload)
        payload[:operation] ? "clicksend #{payload[:operation]}" : "clicksend #{payload[:http_method].to_s.upcase}"
      end

      def start_attributes(payload)
        attributes = @server.merge(
          "http.request.method" => payload[:http_method].to_s.upcase,
          "clicksend.operation" => payload[:operation],
          "clicksend.idempotent" => payload[:idempotent]
        )
        attributes["url.path"] = payload[:path] if @record_path
        attributes.compact
      end

      # Class, HTTP status, ClickSend's response_code and the request line:
      # all already present in the request.clicksend payload.
      def safe_message(error)
        parts = [error.class.name]
        parts << "HTTP #{error.http_status}" if error.respond_to?(:http_status) && error.http_status
        parts << error.response_code if error.respond_to?(:response_code) && error.response_code.is_a?(String)
        parts << "(#{error.request})" if error.is_a?(Clicksend::Error) && error.request
        parts.join(" ")
      end

      def safely
        yield
      rescue => e
        ::OpenTelemetry.handle_error(exception: e, message: "clicksend-opentelemetry")
        nil
      end
    end

    # Sends every event to several instrumenters by nesting them, so the
    # request still runs exactly once:
    #
    #   Clicksend::OpenTelemetry::FanOut.new(ActiveSupport::Notifications, Clicksend::OpenTelemetry::Instrumenter.new)
    #
    # The first instrumenter is the outermost. Put the OpenTelemetry one last:
    # its span then covers only the request, and an exception raised by an
    # outer subscriber after the request finished (which the client ignores)
    # is never recorded as the span's error.
    class FanOut
      def initialize(*instrumenters)
        raise ArgumentError, "every instrumenter must respond to #instrument" unless instrumenters.all? { |i| i.respond_to?(:instrument) }

        @instrumenters = instrumenters.freeze
        freeze
      end

      def instrument(name, payload = {}, &block)
        chain = @instrumenters.reverse.reduce(block) do |inner, instrumenter|
          proc { |yielded| instrumenter.instrument(name, yielded || payload, &inner) }
        end
        chain&.call(payload)
      end

      def inspect
        "#<#{self.class.name} #{@instrumenters.map(&:inspect).join(", ")}>"
      end
    end
  end
end
