# frozen_string_literal: true

require "uri"

module Clicksend
  # Entry point. A Client holds credentials and HTTP settings, is immutable,
  # and is safe to share between threads (one per set of credentials).
  #
  #   client = Clicksend::Client.new(username: "...", api_key: "...")
  #   client.sms.deliver(to: "+61411111111", body: "Hello")
  #
  # Every call, wrapped or not, goes through #request: the same Basic
  # authentication, timeouts, retry rules, error mapping and response parsing.
  class Client
    DEFAULT_BASE_URL = "https://rest.clicksend.com"
    DEFAULT_TIMEOUT = 30
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_MAX_RETRIES = 2
    LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1 [::1]].freeze

    attr_reader :username, :base_url, :timeout, :open_timeout

    # @return [#delay, #max_retries] see Clicksend::RetryPolicy
    attr_reader :retry_policy

    # @return [#instrument] see Clicksend::Instrumentation
    attr_reader :instrumenter

    # @return [Clicksend::Resources::Account]
    attr_reader :account

    # @return [Clicksend::Resources::SMS]
    attr_reader :sms

    # @param username [String] API username (default: ENV["CLICKSEND_USERNAME"])
    # @param api_key [String] API key (default: ENV["CLICKSEND_API_KEY"])
    # @param base_url [String] ClickSend API origin; HTTPS only (plain HTTP is
    #   allowed for localhost, e.g. a test server)
    # @param timeout [Numeric] seconds to wait for a response (read timeout)
    # @param open_timeout [Numeric] seconds to wait for the TCP/TLS connection
    # @param max_retries [Integer] retries for failures that are safe to retry
    #   (see Clicksend::RetryPolicy); 0 disables retries. Default 2. A shortcut
    #   for +retry_policy: RetryPolicy.new(max_retries: n)+; pass one or the other.
    # @param retry_policy [#delay, #max_retries] backoff timing and retry budget
    #   (see Clicksend::RetryPolicy). Which failures are retried at all is not
    #   configurable.
    # @param logger [#info, #warn, nil] receives one line per HTTP attempt;
    #   never request/response bodies, query strings or credentials
    # @param instrumenter [#instrument, nil] e.g. ActiveSupport::Notifications;
    #   see Clicksend::Instrumentation for the events and their payloads
    # @param adapter [Symbol, Array, nil] Faraday adapter (default Net::HTTP)
    # @param transport [#call, nil] replaces the HTTP layer entirely (see
    #   Clicksend::Transport and Clicksend::Testing::FakeAPI); +timeout+,
    #   +open_timeout+ and +adapter+ are then the transport's responsibility
    def initialize(
      username: ENV.fetch("CLICKSEND_USERNAME", nil),
      api_key: ENV.fetch("CLICKSEND_API_KEY", nil),
      base_url: DEFAULT_BASE_URL,
      timeout: DEFAULT_TIMEOUT,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      max_retries: nil,
      retry_policy: nil,
      logger: nil,
      instrumenter: nil,
      adapter: nil,
      transport: nil
    )
      @username = credential!(username, "username", "CLICKSEND_USERNAME")
      api_key = credential!(api_key, "api_key", "CLICKSEND_API_KEY")
      @base_url = normalize_base_url!(base_url)
      @timeout = positive_number!(timeout, "timeout")
      @open_timeout = positive_number!(open_timeout, "open_timeout")
      @retry_policy = build_retry_policy(max_retries, retry_policy)
      @instrumenter = instrumenter || Instrumentation::Null
      unless @instrumenter.respond_to?(:instrument)
        raise ConfigurationError, "instrumenter must respond to #instrument(name, payload) { ... }"
      end

      @settings = {
        username: @username, api_key: api_key, base_url: @base_url, timeout: @timeout,
        open_timeout: @open_timeout, max_retries: max_retries, retry_policy: retry_policy, logger: logger,
        instrumenter: instrumenter, adapter: adapter, transport: transport
      }.freeze

      @connection = Connection.new(
        transport: transport || Transport::Faraday.new(base_url: @base_url, timeout: @timeout, open_timeout: @open_timeout, adapter: adapter),
        retry_policy: @retry_policy,
        headers: {
          "Authorization" => "Basic #{["#{@username}:#{api_key}"].pack("m0")}",
          "Accept" => "application/json",
          "User-Agent" => "clicksend-ruby/#{VERSION} ruby/#{RUBY_VERSION}"
        },
        logger: logger,
        instrumenter: @instrumenter
      )
      @account = Resources::Account.new(self)
      @sms = Resources::SMS.new(self)
      freeze
    end

    # Retries allowed after a failed attempt (from the retry policy).
    def max_retries
      retry_policy.max_retries
    end

    # Calls any ClickSend v3 endpoint, wrapped by this gem or not.
    #
    #   client.request(:get, "/v3/sms/history", query: {date_from: (Time.now - 86_400).to_i})
    #   client.request(:post, "/v3/sms/templates", body: {template_name: "otp", body: "Code: {code}"})
    #
    # Paths are written exactly as in ClickSend's API reference (starting with
    # "/v3/"). Full URLs are rejected so credentials can never be sent to
    # another host.
    #
    # @param method [Symbol] :get, :post, :put, :patch or :delete
    # @param query [Hash, nil] query parameters; nil values are dropped
    # @param body [Hash, Array, nil] JSON request body
    # @param idempotent [Boolean, nil] whether the request is safe to repeat if
    #   it may already have reached ClickSend (timeouts, 5xx). Defaults to true
    #   for GET only: ClickSend uses POST/PUT for operations such as sending
    #   messages and buying credit, so they are not assumed to be repeatable.
    #   A failure of a non-idempotent request that may have been processed is
    #   a Clicksend::AmbiguousRequestError.
    # @param operation [String, nil] a label for logs and instrumentation,
    #   e.g. "templates.create"; wrapped methods use names like "sms.deliver"
    # @return [Clicksend::Response]
    # @raise [Clicksend::Error] see the error hierarchy in errors.rb
    def request(method, path, query: nil, body: nil, idempotent: nil, operation: nil)
      method = method.to_s.downcase.to_sym
      unless Connection::HTTP_METHODS.include?(method)
        raise ArgumentError, "unsupported HTTP method #{method.inspect}; use one of #{Connection::HTTP_METHODS.join(", ")}"
      end
      validate_path!(path)
      raise ArgumentError, "query must be a Hash" unless query.nil? || query.is_a?(Hash)
      raise ArgumentError, "operation must be a String" unless operation.nil? || operation.is_a?(String)

      @connection.request(
        method, path,
        query: query&.compact,
        body: body,
        idempotent: idempotent.nil? ? method == :get : idempotent == true,
        operation: operation
      )
    end

    # Fetches one page of any paginated ClickSend list endpoint, as raw Hashes.
    #
    #   page = client.paginate("/v3/sms/history", query: {date_from: from.to_i}, limit: 100)
    #   page.auto_paging_each { |message| ... }
    #
    # @return [Clicksend::Page]
    def paginate(path, query: {}, page: nil, limit: nil, operation: nil)
      Page.fetch(self, path, query: query, page: page, limit: limit, operation: operation)
    end

    # Returns a new client with some settings changed, e.g. a subaccount's
    # credentials or a shorter timeout for a latency-sensitive code path.
    # Overriding +max_retries+ replaces the retry policy, and vice versa.
    def with(**overrides)
      unknown = overrides.keys - @settings.keys
      raise ArgumentError, "unknown setting(s): #{unknown.join(", ")}" unless unknown.empty?

      settings = @settings
      settings = settings.merge(retry_policy: nil) if overrides.key?(:max_retries)
      settings = settings.merge(max_retries: nil) if overrides.key?(:retry_policy)
      self.class.new(**settings, **overrides)
    end

    def inspect
      "#<#{self.class.name} username=#{username.inspect} base_url=#{base_url.inspect}>"
    end
    alias_method :to_s, :inspect

    private

    # Surrounding whitespace (e.g. a trailing newline from a secrets file) is
    # stripped; ClickSend usernames and API keys never contain it.
    def credential!(value, name, env_name)
      return value.strip if value.is_a?(String) && !value.strip.empty?

      raise ConfigurationError, "Missing ClickSend #{name}: pass #{name}: or set #{env_name}"
    end

    def build_retry_policy(max_retries, retry_policy)
      unless max_retries.nil? || retry_policy.nil?
        raise ConfigurationError, "pass max_retries: or retry_policy:, not both"
      end
      return RetryPolicy.new(max_retries: max_retries.nil? ? DEFAULT_MAX_RETRIES : max_retries) if retry_policy.nil?
      return retry_policy if retry_policy.respond_to?(:delay) && retry_policy.respond_to?(:max_retries)

      raise ConfigurationError, "retry_policy must respond to #delay(error:, attempt:) and #max_retries"
    end

    def positive_number!(value, name)
      return value if value.is_a?(Numeric) && value.positive?

      raise ConfigurationError, "#{name} must be a positive number of seconds"
    end

    def normalize_base_url!(value)
      uri = URI.parse(value.to_s)
      local = LOCAL_HOSTS.include?(uri.host)
      valid = uri.host && (uri.scheme == "https" || (uri.scheme == "http" && local)) &&
        uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && ["", "/"].include?(uri.path)
      raise ConfigurationError, "base_url must be an https:// origin such as #{DEFAULT_BASE_URL}" unless valid

      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
    rescue URI::InvalidURIError
      raise ConfigurationError, "base_url is not a valid URL: #{value.inspect}"
    end

    # Only a path on the configured host is accepted: no scheme, no host, no
    # leading "//" (even "///host", which Faraday keeps on the origin but a
    # custom transport could resolve as a network-path reference), no
    # whitespace or control characters, nothing URI can't parse.
    def validate_path!(path)
      plain = path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") && !path.match?(/[[:cntrl:] ]/)
      uri = URI.parse(path) if plain
      return if uri && uri.scheme.nil? && uri.host.nil?

      raise ArgumentError, "path must be an absolute path such as \"/v3/account\", not #{path.inspect}"
    rescue URI::InvalidURIError
      raise ArgumentError, "path must be an absolute path such as \"/v3/account\", not #{path.inspect}"
    end
  end
end
