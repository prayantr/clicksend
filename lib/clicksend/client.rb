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

    attr_reader :username, :base_url, :timeout, :open_timeout, :max_retries

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
    #   (see Clicksend::RetryPolicy); 0 disables retries
    # @param logger [#info, #warn, nil] receives one line per HTTP attempt;
    #   never request/response bodies, query strings or credentials
    # @param adapter [Symbol, Array, nil] Faraday adapter (default Net::HTTP)
    # @param transport [#call, nil] replaces the HTTP layer entirely (see
    #   Clicksend::Transport); +timeout+, +open_timeout+ and +adapter+ are then
    #   the transport's responsibility
    def initialize(
      username: ENV.fetch("CLICKSEND_USERNAME", nil),
      api_key: ENV.fetch("CLICKSEND_API_KEY", nil),
      base_url: DEFAULT_BASE_URL,
      timeout: DEFAULT_TIMEOUT,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      max_retries: DEFAULT_MAX_RETRIES,
      logger: nil,
      adapter: nil,
      transport: nil
    )
      @username = credential!(username, "username", "CLICKSEND_USERNAME")
      api_key = credential!(api_key, "api_key", "CLICKSEND_API_KEY")
      @base_url = normalize_base_url!(base_url)
      @timeout = positive_number!(timeout, "timeout")
      @open_timeout = positive_number!(open_timeout, "open_timeout")
      unless max_retries.is_a?(Integer) && max_retries >= 0
        raise ConfigurationError, "max_retries must be a non-negative Integer"
      end
      @max_retries = max_retries

      @settings = {
        username: @username, api_key: api_key, base_url: @base_url, timeout: @timeout,
        open_timeout: @open_timeout, max_retries: @max_retries, logger: logger,
        adapter: adapter, transport: transport
      }.freeze

      @connection = Connection.new(
        transport: transport || Transport::Faraday.new(base_url: @base_url, timeout: @timeout, open_timeout: @open_timeout, adapter: adapter),
        retry_policy: RetryPolicy.new(max_retries: @max_retries),
        headers: {
          "Authorization" => "Basic #{["#{@username}:#{api_key}"].pack("m0")}",
          "Accept" => "application/json",
          "User-Agent" => "clicksend-ruby/#{VERSION} ruby/#{RUBY_VERSION}"
        },
        logger: logger
      )
      @account = Resources::Account.new(self)
      @sms = Resources::SMS.new(self)
      freeze
    end

    # Calls any ClickSend v3 endpoint, wrapped by this gem or not.
    #
    #   client.request(:get, "/v3/sms/history", query: {date_from: 1.day.ago.to_i})
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
    # @return [Clicksend::Response]
    # @raise [Clicksend::Error] see the error hierarchy in errors.rb
    def request(method, path, query: nil, body: nil, idempotent: nil)
      method = method.to_s.downcase.to_sym
      unless Connection::HTTP_METHODS.include?(method)
        raise ArgumentError, "unsupported HTTP method #{method.inspect}; use one of #{Connection::HTTP_METHODS.join(", ")}"
      end
      validate_path!(path)
      raise ArgumentError, "query must be a Hash" unless query.nil? || query.is_a?(Hash)

      @connection.request(
        method, path,
        query: query&.compact,
        body: body,
        idempotent: idempotent.nil? ? method == :get : idempotent
      )
    end

    # Fetches one page of any paginated ClickSend list endpoint, as raw Hashes.
    #
    #   page = client.paginate("/v3/sms/history", query: {date_from: from.to_i}, limit: 100)
    #   page.auto_paging_each { |message| ... }
    #
    # @return [Clicksend::Page]
    def paginate(path, query: {}, page: nil, limit: nil)
      Page.fetch(self, path, query: query, page: page, limit: limit)
    end

    # Returns a new client with some settings changed, e.g. a subaccount's
    # credentials or a shorter timeout for a latency-sensitive code path.
    def with(**overrides)
      unknown = overrides.keys - @settings.keys
      raise ArgumentError, "unknown setting(s): #{unknown.join(", ")}" unless unknown.empty?

      self.class.new(**@settings, **overrides)
    end

    def inspect
      "#<#{self.class.name} username=#{username.inspect} base_url=#{base_url.inspect}>"
    end
    alias_method :to_s, :inspect

    private

    def credential!(value, name, env_name)
      return value if value.is_a?(String) && !value.strip.empty?

      raise ConfigurationError, "Missing ClickSend #{name}: pass #{name}: or set #{env_name}"
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

    def validate_path!(path)
      return if path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") && !path.match?(/[[:cntrl:] ]/)

      raise ArgumentError, "path must be an absolute path such as \"/v3/account\", not #{path.inspect}"
    end
  end
end
