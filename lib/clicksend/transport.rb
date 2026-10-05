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
  # where +body+ is an already-encoded String (or nil), and that raises
  # Clicksend::ConnectionError / Clicksend::TimeoutError when no HTTP response
  # was received. Pass a custom one to Client.new(transport:) to replace Faraday.
  module Transport
    # A raw HTTP response: Integer status, Hash of lower-cased headers, String body.
    Response = Data.define(:status, :headers, :body)

    # The default transport, built on Faraday 2.
    class Faraday
      # Low-level failures that happen before the request is written to the
      # socket. A request that failed this way cannot have reached ClickSend.
      NOT_SENT_ERRORS = [
        "Errno::ECONNREFUSED", "Errno::EHOSTUNREACH", "Errno::ENETUNREACH",
        "SocketError", "Net::OpenTimeout", "OpenSSL::SSL::SSLError"
      ].freeze

      # @param adapter [Symbol, Array, nil] a Faraday adapter name, optionally
      #   with arguments (e.g. +[:net_http_persistent, {pool_size: 5}]+).
      #   Defaults to Faraday.default_adapter (Net::HTTP).
      def initialize(base_url:, username:, api_key:, timeout:, open_timeout:, user_agent:, adapter: nil)
        @connection = ::Faraday.new(
          url: base_url,
          headers: {"User-Agent" => user_agent, "Accept" => "application/json"},
          request: {timeout: timeout, open_timeout: open_timeout}
        ) do |builder|
          builder.request :authorization, :basic, username, api_key
          builder.adapter(*Array(adapter || ::Faraday.default_adapter))
        end
      end

      def call(method, path, query: nil, body: nil, headers: {})
        response = @connection.run_request(method, path, body, headers) do |request|
          request.params.update(query) if query
        end
        Response.new(
          status: response.status,
          headers: response.headers.to_h.transform_keys { |key| key.to_s.downcase },
          body: response.body.to_s
        )
      rescue ::Faraday::TimeoutError => e
        raise Clicksend::TimeoutError, "Timed out waiting for ClickSend: #{e.message}"
      rescue ::Faraday::ConnectionFailed, ::Faraday::SSLError => e
        raise translate_connection_failure(e)
      end

      private

      def translate_connection_failure(error)
        cause = error.wrapped_exception || error.cause
        not_sent = cause && cause.class.ancestors.any? { |klass| NOT_SENT_ERRORS.include?(klass.name) }
        error_class = (cause&.class&.name == "Net::OpenTimeout") ? Clicksend::TimeoutError : Clicksend::ConnectionError
        error_class.new("Could not reach ClickSend: #{error.message}", request_sent: not_sent ? false : nil)
      end
    end
  end
end
