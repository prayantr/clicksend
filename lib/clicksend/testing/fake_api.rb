# frozen_string_literal: true

module Clicksend
  module Testing
    # An in-memory ClickSend, used as a Client's transport.
    #
    #   fake = Clicksend::Testing::FakeAPI.new
    #   client = fake.client # or Client.new(username: "u", api_key: "k", transport: fake)
    #   client.sms.deliver(to: "+61411111111", body: "Hi", custom_string: "otp:42")
    #   fake.sent_messages.last.custom_string # => "otp:42"
    #
    # It emulates these endpoints, with ClickSend's response shapes:
    # POST /v3/sms/send, GET /v3/account, receipts and inbound (list, one
    # receipt, mark read), and cancelling a scheduled message. Anything else
    # answers 404 unless #stub-bed.
    #
    # It deliberately does not serve GET /v3/sms/history by itself. ClickSend
    # doesn't say how soon a sent message appears there, and an always-up-to-
    # date fake history would let a "not in history, so resend" rule pass its
    # tests and then send twice in production. To test reconciliation code,
    # say what history shows with #stub_history, including nothing.
    #
    # Cancelling (PUT /v3/sms/{message_id}/cancel) succeeds for a message the
    # fake accepted with a schedule still in the future. ClickSend doesn't
    # document its answer for any other message (unknown, already sent, already
    # cancelled), so the fake raises Testing::StubError for those: #stub the
    # answer your test assumes.
    #
    # Recipients can be rejected (#reject), failures injected (#fail_next) and
    # receipts and replies seeded (#add_receipt, #add_inbound).
    #
    # Simplifications, so tests don't come to depend on them:
    # - the balance never changes; +message_parts+ is an estimate (one per
    #   160 characters);
    # - a recipient that is not 6 to 15 digits (optionally after "+") gets
    #   "INVALID_RECIPIENT"; the real rules are ClickSend's own;
    # - mark-read with +date_before+ marks items whose +timestamp+ is strictly
    #   earlier (ClickSend does not document whether the cutoff is inclusive).
    #
    # Exceptions raised by #stub blocks or the +clock:+ surface as
    # Testing::StubError, never as a simulated ClickSend failure.
    #
    # Thread-safe. Stub blocks run outside the lock, so they may call the fake.
    class FakeAPI
      Entry = Struct.new(:payload, :read)
      private_constant :Entry

      DECIMAL = /\A\d+(\.\d+)?\z/
      RECIPIENT = /\A\+?\d{6,15}\z/
      # What a bug in a stub block or clock raises. Anything else (Interrupt,
      # SystemExit, Timeout's internal exception, RSpec or Minitest assertion
      # failures) is not a mistake in the fake's setup and passes through as is.
      MISTAKES = [StandardError, ScriptError].freeze
      STATUS_TEXTS = {200 => "Sent", 201 => "Delivered", 300 => "Retrying", 301 => "Failed"}.freeze
      # The history statuses ClickSend documents for outbound messages.
      HISTORY_STATUSES = %w[Queued Completed Scheduled WaitApproval Failed Cancelled CancelledAfterReview Sent].freeze
      ROUTES = [
        [:post, %r{\A/v3/sms/send\z}, :send_sms],
        [:get, %r{\A/v3/account\z}, :account],
        [:get, %r{\A/v3/sms/receipts\z}, :list_receipts],
        [:get, %r{\A/v3/sms/receipts/([A-Za-z0-9-]+)\z}, :show_receipt],
        [:put, %r{\A/v3/sms/receipts-read\z}, :mark_receipts_read],
        [:get, %r{\A/v3/sms/inbound\z}, :list_inbound],
        [:put, %r{\A/v3/sms/inbound-read\z}, :mark_inbound_read],
        [:put, %r{\A/v3/sms/inbound-read/([A-Za-z0-9-]+)\z}, :mark_inbound_message_read],
        [:put, %r{\A/v3/sms/([A-Za-z0-9-]+)/cancel\z}, :cancel_sms]
      ].freeze
      private_constant :DECIMAL, :RECIPIENT, :MISTAKES, :STATUS_TEXTS, :HISTORY_STATUSES, :ROUTES

      # @param balance [String] the account balance, as ClickSend's decimal String
      # @param currency [String] e.g. "AUD"
      # @param message_price [String] price per message part, e.g. "0.0792"
      # @param clock [#call] returns the current Time; pass a fixed one to freeze time
      def initialize(balance: "10.000000", currency: "AUD", message_price: "0.0000", clock: -> { Time.now })
        raise ArgumentError, "balance must be a decimal String such as \"10.000000\"" unless balance.is_a?(String) && balance.match?(DECIMAL)
        raise ArgumentError, "message_price must be a decimal String such as \"0.0792\"" unless message_price.is_a?(String) && message_price.match?(DECIMAL)
        raise ArgumentError, "currency must be a currency code String such as \"AUD\"" unless currency.is_a?(String) && !currency.empty?
        raise ArgumentError, "clock must respond to #call and return a Time" unless clock.respond_to?(:call)

        @balance = balance.dup.freeze
        @currency = currency.dup.freeze
        @message_price = message_price.dup.freeze
        @clock = clock
        @lock = Mutex.new
        @outbox = [] # [SentMessage, accepted payload]
        @cancelled = {} # message_id => SentMessage
        @requests = []
        @receipts = []
        @latest_receipts = {} # message_id => payload
        @inbound = []
        @rules = []
        @failures = [] # [Failure, remaining]
        @stubs = {}
      end

      # A real Clicksend::Client using this fake, with the production retry
      # rules but no backoff delay. A 429's Retry-After is still honoured
      # (injected 429s default to 0 seconds).
      # @param overrides [Hash] any Client.new option. As with Client.new,
      #   +max_retries:+ and +retry_policy:+ together raise ConfigurationError.
      # @return [Clicksend::Client]
      def client(**overrides)
        defaults = {username: "test", api_key: "test", transport: self}
        unless overrides.key?(:retry_policy)
          retries = {max_retries: overrides.delete(:max_retries)}.compact
          defaults[:retry_policy] = RetryPolicy.new(**retries, base_delay: 0, max_delay: 0)
        end
        Client.new(**defaults.merge(overrides))
      end

      # Messages accepted (status "SUCCESS"), oldest first.
      # @return [Array<SentMessage>] a frozen snapshot
      def sent_messages
        @lock.synchronize { @outbox.map(&:first) }.freeze
      end

      # Scheduled messages cancelled through PUT /v3/sms/{message_id}/cancel,
      # in the order they were cancelled. They stay in #sent_messages: ClickSend
      # accepted them.
      # @return [Array<SentMessage>] a frozen snapshot
      def cancelled_messages
        @lock.synchronize { @cancelled.values }.freeze
      end

      # Every request received, oldest first, including failed ones.
      # @return [Array<Request>] a frozen snapshot
      def requests
        @lock.synchronize { @requests.dup }.freeze
      end

      # Forgets messages, cancellations, requests, receipts, inbound messages, rejection
      # rules, pending failures and stubs. Constructor settings are kept.
      # @return [self]
      def reset!
        @lock.synchronize { [@outbox, @cancelled, @requests, @receipts, @latest_receipts, @inbound, @rules, @failures, @stubs].each(&:clear) }
        self
      end

      # Gives every later message to +to+ (or, without +to+, every message)
      # the per-message status +status+ instead of "SUCCESS". The most recent
      # matching rule wins. A single #deliver then raises MessageRejected.
      # "COUNTRY_NOT_ENABLED" rejections are counted in +blocked_count+.
      # @return [self]
      def reject(status:, to: nil)
        unless status.is_a?(String) && status.match?(/\A[A-Z][A-Z0-9_]*\z/) && status != "SUCCESS"
          raise ArgumentError, "status must be a ClickSend per-message status such as \"INVALID_RECIPIENT\", got #{status.inspect}"
        end
        raise ArgumentError, "to must be a phone number String, or nil for every recipient" unless to.nil? || to.is_a?(String)

        @lock.synchronize { @rules << [to, status].freeze }
        self
      end

      # Makes the next matching request(s) fail, oldest instruction first.
      #
      #   fake.fail_next(:connection_refused)              # never sent: retried by the client
      #   fake.fail_next(:open_timeout)                    # never sent: retried by the client
      #   fake.fail_next(:timeout, processed: true)        # accepted, response lost
      #   fake.fail_next(:connection_reset, processed: false)
      #   fake.fail_next(status: 500, processed: false)
      #   fake.fail_next(status: 429, retry_after: 0)      # never processed
      #   fake.fail_next(status: 401)                      # any 4xx; never processed
      #   fake.fail_next(:interrupted, processed: true)    # the worker is stopped mid-send
      #
      # +processed:+ is required exactly when the outcome is ambiguous (a read
      # timeout, a reset, a 5xx or an interruption): with +true+ the request is
      # handled first (a send is recorded), then the failure is returned; with
      # +false+ it is not.
      #
      # +:interrupted+ is not a ClickSend failure. It models your job runner
      # stopping the worker during the call (Sidekiq's shutdown raising
      # Sidekiq::Shutdown into busy threads, for example) by raising
      # SimulatedInterrupt, which is not a StandardError: the client lets it
      # through untouched and never retries it. Use it to test what the next
      # run of the job does, e.g. that an in-flight marker stops it sending
      # again.
      #
      # @param path [String, nil] only requests to this exact path
      # @param method [Symbol, nil] only requests with this HTTP method
      # @param times [Integer] how many matching requests fail
      # @return [self]
      def fail_next(outcome = nil, status: nil, processed: nil, retry_after: nil, path: nil, method: nil, times: 1)
        failure = Failure.new(outcome, status: status, processed: processed, retry_after: retry_after, path: path, method: method, times: times)
        @lock.synchronize { @failures << [failure, failure.times] }
        self
      end

      # Answers +method+ +path+ (exact path, no query) with the block's result,
      # in place of the built-in endpoint or the 404. The block receives a
      # Request and returns a Hash (sent as a 200 envelope, unless it has its
      # own "http_code") or a Clicksend::Transport::Response.
      #
      #   fake.stub(:get, "/v3/sms/templates") { |request| {"data" => {"data" => []}} }
      # @return [self]
      def stub(method, path, &block)
        method = method.to_s.downcase.to_sym
        raise ArgumentError, "method must be one of #{Connection::HTTP_METHODS.join(", ")}" unless Connection::HTTP_METHODS.include?(method)
        raise ArgumentError, "path must be a String such as \"/v3/sms/templates\", without a query" unless path.is_a?(String) && path.start_with?("/") && !path.include?("?")
        raise ArgumentError, "stub needs a block" unless block

        @lock.synchronize { @stubs[[method, path]] = block }
        self
      end

      # Says what GET /v3/sms/history shows from now on: exactly +messages+
      # (SentMessages from #sent_messages), each with history status +status+,
      # in the order given, or nothing at all. Every history request gets these
      # rows, whatever its q, date or order parameters: you are stating what
      # ClickSend shows for the query your code makes, at that point in your
      # scenario. Call it again to change what history shows. Rows have
      # ClickSend's history shape as observed live (status_code null).
      #
      #   fake.stub_history                                     # nothing (yet)
      #   fake.stub_history(fake.sent_messages.last)            # this message, "Sent"
      #   fake.stub_history(message, status: "Cancelled")
      # @return [self]
      def stub_history(*messages, status: "Sent")
        messages.each { |message| sent_message!(message, "messages") }
        unless HISTORY_STATUSES.include?(status)
          raise ArgumentError, "status must be one of ClickSend's outbound history statuses (#{HISTORY_STATUSES.join(", ")}), got #{status.inspect}"
        end

        rows = messages.map { |message| Payloads.history_row(message, status, @message_price) }.freeze
        stub(:get, "/v3/sms/history") { |request| Payloads.page(rows, request.path, request.query, "Here are your history.") }
      end

      # Seeds a delivery receipt, unread. Pass +message_id:+, or +for:+ a
      # SentMessage to take its message_id, custom_string and send time.
      #
      #   fake.add_receipt(for: fake.sent_messages.last, status_code: 301, error_code: 3, error_text: "Expired")
      #
      # @param status_code [Integer] gateway code: 200, 201 (delivered), 300, 301 (failed)
      # @param status_text [String, nil] defaults to a word for the code ("Delivered", "Failed", ...)
      # @param timestamp [Time, Integer, nil] when the receipt arrived (default: now)
      # @param timestamp_send [Time, Integer, nil] when the message was sent (default: +timestamp+)
      # @return [Clicksend::SMS::Receipt] built from the payload the API returns
      def add_receipt(message_id: nil, for: nil, status_code: 201, status_text: nil, error_code: nil, error_text: nil,
        custom_string: nil, timestamp: nil, timestamp_send: nil)
        sent = binding.local_variable_get(:for)
        raise ArgumentError, "pass message_id: or for:, not both" if sent && message_id
        if sent
          sent_message!(sent, "for")
          message_id = sent.message_id
          custom_string ||= sent.custom_string
          timestamp_send ||= sent.sent_at
        end
        message_id!(message_id)
        raise ArgumentError, "status_code must be an Integer gateway code such as 201" unless status_code.is_a?(Integer)
        raise ArgumentError, "error_code must be an Integer or nil" unless error_code.nil? || error_code.is_a?(Integer)
        strings!(status_text: status_text, error_text: error_text, custom_string: custom_string)

        received = unix(timestamp || now, "timestamp")
        payload = {
          "timestamp_send" => timestamp_send ? unix(timestamp_send, "timestamp_send") : received, "timestamp" => received,
          "message_id" => message_id, "status_code" => status_code,
          "status_text" => status_text || STATUS_TEXTS.fetch(status_code, "Status #{status_code}"),
          "error_code" => error_code, "error_text" => error_text, "custom_string" => custom_string,
          "subaccount_id" => Payloads::SUBACCOUNT_ID, "message_type" => "sms"
        }.freeze
        @lock.synchronize do
          @receipts << Entry.new(payload, false)
          @latest_receipts[payload["message_id"]] = payload
        end
        SMS::Receipt.from_api(payload)
      end

      # Seeds an inbound SMS (a reply), unread. With +reply_to:+ a SentMessage,
      # +from+ defaults to its recipient, +to+ to its sender and the original_*
      # fields and custom_string come from it.
      #
      #   fake.add_inbound(reply_to: fake.sent_messages.last, body: "STOP")
      #
      # @param timestamp [Time, Integer, nil] when it arrived (default: now)
      # @return [Clicksend::SMS::InboundMessage] built from the payload the API returns
      def add_inbound(body:, from: nil, to: nil, original_message_id: nil, original_body: nil, custom_string: nil, timestamp: nil, reply_to: nil)
        if reply_to
          sent_message!(reply_to, "reply_to")
          from ||= reply_to.to
          to ||= reply_to.from
          original_message_id ||= reply_to.message_id
          original_body ||= reply_to.body
          custom_string ||= reply_to.custom_string
        end
        raise ArgumentError, "from must be the sender's phone number (a non-empty String)" unless from.is_a?(String) && !from.empty?
        raise ArgumentError, "body must be a String" unless body.is_a?(String)
        strings!(to: to, original_message_id: original_message_id, original_body: original_body, custom_string: custom_string)

        payload = {
          "timestamp" => unix(timestamp || now, "timestamp"), "from" => from, "body" => body,
          "original_body" => original_body, "original_message_id" => original_message_id, "to" => to,
          "custom_string" => custom_string || "", "message_id" => SecureRandom.uuid.upcase
        }.freeze
        @lock.synchronize { @inbound << Entry.new(payload, false) }
        SMS::InboundMessage.from_api(payload)
      end

      # The transport interface (see Clicksend::Transport). +headers+ are
      # ignored and never stored: they hold the credentials.
      # @return [Clicksend::Transport::Response]
      # @raise [Clicksend::ConnectionError] for injected connection failures
      # @raise [SimulatedInterrupt] for fail_next(:interrupted)
      def call(method, path, query: nil, body: nil, headers: nil)
        request = build_request(method, path, query, body)
        failure, stub = @lock.synchronize do
          @requests << request
          [take_failure(request), @stubs[[request.http_method, request.path]]]
        end
        return failure.trigger if failure && !failure.processed?

        response = stub ? stubbed(stub, request) : @lock.synchronize { route(request) }
        failure ? failure.trigger : response
      end

      def inspect
        @lock.synchronize { "#<#{self.class.name} sent_messages=#{@outbox.size} requests=#{@requests.size}>" }
      end
      alias_method :to_s, :inspect

      private

      def build_request(method, path, query, body)
        path, raw_query = path.to_s.split("?", 2)
        params = raw_query ? URI.decode_www_form(raw_query).to_h : {}
        (query || {}).each { |key, value| params[key.to_s] = value.to_s }
        parsed = begin
          JSON.parse(body, freeze: true) unless body.nil?
        rescue JSON::ParserError
          body.dup.freeze
        end
        Request.new(http_method: method.to_s.downcase.to_sym, path: path.freeze, query: params.to_h { |k, v| [k.freeze, v.freeze] }.freeze, body: parsed)
      end

      def take_failure(request)
        index = @failures.index { |failure, _| failure.matches?(request) }
        return unless index

        slot = @failures[index]
        slot[1] -= 1
        @failures.delete_at(index) if slot[1].zero?
        slot[0]
      end

      def stubbed(stub, request)
        result = begin
          stub.call(request)
        rescue *MISTAKES => e
          raise StubError, "the FakeAPI stub for #{request.http_method.upcase} #{request.path} raised #{e.class}: #{e.message}"
        end
        return result if result.is_a?(Transport::Response)
        raise StubError, "a FakeAPI stub must return a Hash or a Clicksend::Transport::Response, got #{result.class}" unless result.is_a?(Hash)

        body = result.transform_keys(&:to_s)
        body = {"http_code" => 200, "response_code" => "SUCCESS", "response_msg" => "OK"}.merge(body) unless body.key?("http_code")
        Payloads.respond(body["http_code"].is_a?(Integer) ? body["http_code"] : 200, body)
      end

      def route(request)
        ROUTES.each do |verb, pattern, handler|
          match = pattern.match(request.path) if verb == request.http_method
          return __send__(handler, request, *match.captures) if match
        end
        Payloads.error(404)
      end

      def send_sms(request)
        messages = request.body["messages"] if request.body.is_a?(Hash)
        valid = messages.is_a?(Array) && !messages.empty? && messages.all? { |m|
          m.is_a?(Hash) && m["body"].is_a?(String) && (m["to"].is_a?(String) ^ !m["list_id"].nil?)
        }
        return Payloads.error(400, "MISSING_REQUIRED_FIELDS", "Each message needs a body and either to or list_id.") unless valid

        now = self.now
        results = messages.map { |message| submit(message, now) }
        accepted = results.select { |result| result["status"] == "SUCCESS" }
        total = accepted.sum(Rational(0)) { |result| Rational(result["message_price"]) }
        Payloads.ok("Messages queued for delivery.", {
          "total_price" => (total.denominator == 1) ? total.to_i : total.to_f,
          "total_count" => results.size, "queued_count" => accepted.size, "messages" => results,
          "_currency" => Payloads.currency(@currency),
          "blocked_count" => results.count { |result| result["status"] == "COUNTRY_NOT_ENABLED" }
        })
      end

      def submit(message, now)
        id = SecureRandom.uuid.upcase
        rule = @rules.reverse_each.find { |to, _| to.nil? || to == message["to"] }
        return Payloads.rejected(message, id, rule[1]) if rule
        return Payloads.rejected(message, id, "INVALID_RECIPIENT") if message["to"] && !message["to"].match?(RECIPIENT)

        payload = Payloads.accepted(message, id, now, @message_price)
        @outbox << [SentMessage.new(
          message_id: id, to: message["to"], from: message["from"], body: message["body"],
          custom_string: message["custom_string"], list_id: message["list_id"],
          scheduled_at: Integer(message["schedule"], exception: false)&.then { |t| Time.at(t).utc },
          country: message["country"], sent_at: now.getutc
        ), payload]
        payload
      end

      def account(_request)
        Payloads.ok("Here's your account.", {
          "user_id" => Payloads::USER_ID, "username" => "test", "account_name" => "Clicksend::Testing::FakeAPI",
          "balance" => @balance, "country" => "AU", "timezone" => "Australia/Melbourne",
          "_currency" => Payloads.currency(@currency)
        })
      end

      def list_receipts(request)
        Payloads.page(@receipts.reject(&:read).map(&:payload), request.path, request.query, "Here are your delivery receipts.")
      end

      def show_receipt(_request, message_id)
        receipt = latest_receipt(message_id)
        receipt ? Payloads.ok("Your receipt.", receipt) : Payloads.error(404, "NOT_FOUND", "Receipt record not found.")
      end

      def mark_receipts_read(request)
        mark_read(@receipts, request, "Receipts have been marked as read.")
      end

      def list_inbound(request)
        Payloads.page(@inbound.reject(&:read).map(&:payload), request.path, request.query, "Here are your data.")
      end

      def mark_inbound_read(request)
        mark_read(@inbound, request, "Inbound messages have been marked as read.")
      end

      def mark_inbound_message_read(_request, message_id)
        entries = @inbound.select { |entry| !entry.read && entry.payload["message_id"] == message_id }
        entries.each { |entry| entry.read = true }
        Payloads.ok("Inbound messages have been marked as read.", entries.size)
      end

      def cancel_sms(_request, message_id)
        sent, = @outbox.find { |message, _| message.message_id == message_id }
        if sent&.scheduled_at && sent.scheduled_at > now && !@cancelled.key?(message_id)
          @cancelled[message_id] = sent
          return Payloads.ok("Scheduled sms message has been cancelled.", nil)
        end

        raise StubError, "ClickSend doesn't document its answer to cancelling a message that is not scheduled for the future " \
          "(unknown, already sent or already cancelled), so the FakeAPI won't guess: " \
          "stub PUT /v3/sms/#{message_id}/cancel with the answer your test assumes"
      end

      def mark_read(entries, request, message)
        body = request.body.nil? ? {} : request.body
        cutoff = body["date_before"] if body.is_a?(Hash)
        if !body.is_a?(Hash) || !(cutoff.nil? || cutoff.is_a?(Integer))
          return Payloads.error(400, "BAD_REQUEST", "date_before must be a Unix timestamp.")
        end

        entries.each { |entry| entry.read = true if cutoff.nil? || entry.payload["timestamp"] < cutoff }
        Payloads.ok(message, nil)
      end

      def latest_receipt(message_id)
        @latest_receipts[message_id]
      end

      # The clock is test code: its failures are the test's, not ClickSend's.
      def now
        @clock.call
      rescue *MISTAKES => e
        raise StubError, "the FakeAPI clock raised #{e.class}: #{e.message}"
      end

      def message_id!(value)
        return if value.is_a?(String) && value.match?(Resources::SMS::MESSAGE_ID)

        raise ArgumentError, "message_id must be a ClickSend message ID such as \"31BC271B-1E0C-45F6-9E7E-97186C46BB82\", got #{value.inspect}"
      end

      def sent_message!(value, name)
        raise ArgumentError, "#{name}: must be a Clicksend::Testing::SentMessage (from fake.sent_messages)" unless value.is_a?(SentMessage)
      end

      def strings!(**values)
        values.each { |name, value| raise ArgumentError, "#{name} must be a String or nil" unless value.nil? || value.is_a?(String) }
      end

      def unix(value, name)
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(Time)

        raise ArgumentError, "#{name} must be a Time or Unix timestamp, got #{value.inspect}"
      end
    end
  end
end
