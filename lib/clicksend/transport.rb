# frozen_string_literal: true

require "faraday"

module Clicksend
  # The HTTP layer. Everything Faraday-specific lives in this file; the rest of
  # the gem only sees Transport::Response and Clicksend::ConnectionError.
  #
  # A transport is any object that responds to
  #
  #   call(method, path, query:, body:, headers:) # => Clicksend::Transport::Response
  #
  # where +body+ is an already-encoded String (or nil) and +headers+ already
  # include authentication, and that raises Clicksend::ConnectionError /
  # Clicksend::TimeoutError when no HTTP response was received. Transports hold
  # no credentials. Pass a custom one to Client.new(transport:) to replace
  # Faraday; it is then responsible for its own timeouts.
  module Transport
    # A raw HTTP response: Integer status, Hash of lower-cased headers, String body.
    Response = Data.define(:status, :headers, :body)

    # The default transport, built on Faraday 2.
    class Faraday
      # Failures that can only happen before the request is written, so the
      # request cannot have reached ClickSend: connecting (refused, DNS,
      # connect or TLS-handshake timeout) and, with adapter:
      # :net_http_persistent, waiting for a pooled connection
      # (ConnectionPool::TimeoutError, raised by the checkout that precedes
      # everything else). Matched by name, so no adapter is required.
      # Deliberately narrow: TLS errors and unreachable or downed hosts can
      # also occur after the request was sent, so they count as "may have
      # been sent".
      NOT_SENT_ERRORS = ["Errno::ECONNREFUSED", "SocketError", "Net::OpenTimeout", "ConnectionPool::TimeoutError"].freeze

      # @param adapter [Symbol, Array, nil] a Faraday adapter name, optionally
      #   with arguments (e.g. +[:net_http_persistent, {pool_size: 5}]+).
      #   Defaults to Faraday.default_adapter (Net::HTTP).
      def initialize(base_url:, timeout:, open_timeout:, adapter: nil)
        @connection = ::Faraday.new(url: base_url, request: {timeout: timeout, open_timeout: open_timeout}) do |builder|
          builder.adapter(*Array(adapter || ::Faraday.default_adapter))
        end
      end

      def call(method, path, query: nil, body: nil, headers: {})
        response = @connection.run_request(method, path, body, headers) do |request|
          request.params.update(query) if query
        end
        Response.new(
          status: response.status,
          headers: response.headers.to_h.transform_keys { |key| key.to_s.downcase }.freeze,
          body: response.body.to_s
        )
      rescue ::Faraday::TimeoutError => e
        raise Clicksend::TimeoutError.new("Timed out waiting for ClickSend: #{e.message}", request_sent: not_sent?(e) ? false : nil)
      rescue ::Faraday::ConnectionFailed, ::Faraday::SSLError => e
        raise translate_connection_failure(e)
      end

      private

      def translate_connection_failure(error)
        error_class = (failure_cause(error)&.class&.name == "Net::OpenTimeout") ? Clicksend::TimeoutError : Clicksend::ConnectionError
        error_class.new("Could not reach ClickSend: #{error.message}", request_sent: not_sent?(error) ? false : nil)
      end

      def not_sent?(error)
        cause = failure_cause(error)
        !cause.nil? && cause.class.ancestors.any? { |klass| NOT_SENT_ERRORS.include?(klass.name) }
      end

      # The exception the adapter wrapped. net-http-persistent reports a
      # refused connection (only ever raised by connect(2), never once the
      # request is being written) as a Net::HTTP::Persistent::Error raised
      # in its rescue of the Errno, so for that class the Errno, its #cause,
      # is what happened. Its other errors ("host down: ...") keep their
      # own cause, which is not in NOT_SENT_ERRORS.
      def failure_cause(error)
        cause = error.wrapped_exception || error.cause
        persistent = defined?(::Net::HTTP::Persistent::Error) && cause.is_a?(::Net::HTTP::Persistent::Error)
        persistent ? cause.cause : cause
      end
    end
  end
end
