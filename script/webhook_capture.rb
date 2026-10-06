# frozen_string_literal: true

# Captures real ClickSend webhook pushes and redacts them into replay fixtures
# (spec/fixtures/webhooks). Standard library only. See
# research/1.2-webhooks.md, "Capture protocol", before using it.
#
#   CLICKSEND_CAPTURE_SECRET=... ruby script/webhook_capture.rb serve [PORT] [DIR]
#     Listens on 127.0.0.1:PORT (default 9292) for a tunnel to forward to.
#     Saves each request to /<secret>/... as DIR/<time>-<n>.http (default
#     tmp/webhook-captures, mode 0600), answers 200 at once, and answers 404
#     to anything else without saving it. The secret is replaced by ":secret"
#     in what is saved. Stops after 20 captures. CAPTURE_STATUS="500 Internal
#     Server Error" answers saved requests with that instead, to watch retries.
#
#   ruby script/webhook_capture.rb redact CAPTURE.http FIXTURE.http
#     Writes a copy safe to commit: phone numbers become ClickSend test
#     numbers, message text becomes placeholders, IDs become same-shaped fakes,
#     account IDs become 100001/100002, unknown header values become
#     "[redacted]". Field names, order, value types, empty values and
#     timestamps are kept, because they are the evidence. Prints what it could
#     not classify; read the output file before committing it.

require "fileutils"
require "io/wait"
require "json"
require "socket"
require "time"
require "uri"

module WebhookCapture
  REDACTED = "[redacted]"

  # ClickSend's documented test SMS numbers (https://developers.clicksend.com/docs/testing).
  TEST_NUMBERS = %w[+61411111111 +61422222222 +61433333333 +61444444444 +14055555555 +14055555666 +447777777777 +8615555555555].freeze

  PHONE_FIELDS = %w[from to sms originalsenderid].freeze
  TEXT_FIELDS = %w[body message original_body originalmessage custom_string customstring].freeze
  ID_FIELDS = %w[message_id messageid original_message_id originalmessageid].freeze
  ACCOUNT_FIELDS = {"user_id" => 100_001, "subaccount_id" => 100_002}.freeze
  # Not personal, and the point of a capture: kept as sent.
  KEPT_FIELDS = %w[
    timestamp timestamp_send status status_code status_text error_code error_text message_type digits _keyword
  ].freeze
  # Header values kept as sent; every other header keeps its name only.
  KEPT_HEADERS = %w[content-type content-length user-agent accept accept-encoding connection].freeze

  MAX_HEADER_BYTES = 16_384
  MAX_BODY_BYTES = 65_536

  class Error < StandardError; end

  # Saves requests sent to /<secret>/... as raw .http files.
  class Server
    attr_reader :saved

    # +status+ is what a saved request is answered with: "500 Internal Server
    # Error" makes ClickSend retry, so the saved files' times show its schedule.
    def initialize(secret:, dir:, port: 9292, status: "200 OK", read_timeout: 10, log: $stdout)
      raise ArgumentError, "the secret must be at least 16 URL-safe characters" unless secret.match?(/\A[A-Za-z0-9_-]{16,}\z/)
      raise ArgumentError, "status must look like \"200 OK\"" unless status.match?(/\A[1-5]\d\d [A-Za-z ]+\z/)

      @status = status

      @secret = secret
      @dir = dir
      @read_timeout = read_timeout
      @log = log
      @server = TCPServer.new("127.0.0.1", port)
      @saved = []
    end

    def port
      @server.addr[1]
    end

    def run(limit: 20)
      FileUtils.mkdir_p(@dir, mode: 0o700)
      handle(@server.accept) while @saved.size < limit
    ensure
      @server.close
    end

    private

    def handle(socket)
      status = begin
        save(read_request(socket))
      rescue Error => e
        @log.puts("rejected a request: #{e.message}")
        "400 Bad Request"
      end
      socket.write("HTTP/1.1 #{status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    rescue SystemCallError, IOError => e
      @log.puts("lost a connection: #{e.class}")
    ensure
      socket.close
    end

    def save(request)
      request_line, *header_lines = request[:head].split("\r\n")
      http_method, target, version = request_line.to_s.split(" ")
      prefix = "/#{@secret}/"
      return "404 Not Found" unless target&.start_with?(prefix)

      path = "#{@dir}/#{Time.now.utc.strftime("%Y%m%dT%H%M%S%L")}-#{@saved.size + 1}.http"
      head = ["#{http_method} /clicksend/:secret/#{target.delete_prefix(prefix)} #{version}", *header_lines].join("\r\n")
      head = head.gsub(@secret, ":secret") # a proxy may repeat the URL in a header
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("#{head}\r\n\r\n", request[:body]) }
      @saved << path
      @log.puts("saved #{path}: #{http_method}, #{request[:body].bytesize} body bytes")
      @status
    end

    def read_request(socket)
      head = +""
      until head.include?("\r\n\r\n")
        raise Error, "headers over #{MAX_HEADER_BYTES} bytes" if head.bytesize > MAX_HEADER_BYTES

        head << read_some(socket)
      end
      head, body = head.split("\r\n\r\n", 2)
      headers = head.split("\r\n").drop(1).to_h { |line| line.split(":", 2).map { |part| part.to_s.strip.downcase } }
      raise Error, "chunked bodies are not supported; save the request by other means" if headers["transfer-encoding"]

      length = Integer(headers.fetch("content-length", "0"), 10)
      raise Error, "body over #{MAX_BODY_BYTES} bytes" if length > MAX_BODY_BYTES

      body << read_some(socket) while body.bytesize < length
      {head: head, body: body.byteslice(0, length)}
    rescue ArgumentError
      raise Error, "invalid Content-Length"
    end

    def read_some(socket)
      raise Error, "timed out reading the request" unless socket.wait_readable(@read_timeout)

      socket.readpartial(16_384).b
    rescue EOFError
      raise Error, "connection closed mid-request"
    end
  end

  # Redacts one captured request; #notes lists what a person should check.
  class Redactor
    attr_reader :notes

    def initialize
      @notes = []
      @ids = {}
      @phones = {}
      @texts = {}
    end

    def redact(text)
      head, body = text.b.split(/\r?\n\r?\n/, 2)
      request_line, *header_lines = head.force_encoding(Encoding::UTF_8).split(/\r?\n/)
      http_method, target, version = request_line.split(" ")
      path, query = target.split("?", 2)
      raise Error, "the request line has no :secret placeholder; was it saved by `serve`?" unless path.start_with?("/clicksend/:secret/")

      headers = header_lines.map { |line| line.split(":", 2).map(&:strip) }
      body = redact_body(body.to_s, content_type(headers), http_method)
      query = redact_form(query) if query
      headers = headers.map { |name, value| [name, redact_header(name, value, body)] }
      lines = ["#{http_method} #{query ? "#{path}?#{query}" : path} #{version}", *headers.map { |name, value| "#{name}: #{value}" }]
      "#{lines.join("\r\n")}\r\n\r\n#{body}"
    end

    private

    def content_type(headers)
      headers.find { |name, _| name.casecmp?("content-type") }&.last.to_s.split(";").first.to_s.strip.downcase
    end

    def redact_body(body, type, http_method)
      return body if body.empty?

      case type
      when "application/x-www-form-urlencoded" then redact_form(body)
      when "application/json", "text/json" then JSON.generate(redact_fields(JSON.parse(body.dup.force_encoding(Encoding::UTF_8))))
      else raise Error, "#{http_method} body with Content-Type #{type.inspect}: redact it by hand"
      end
    end

    # URI.encode_www_form writes spaces as "+" and escapes what ClickSend may
    # not have; only the decoded fields are evidence.
    def redact_form(text)
      pairs = URI.decode_www_form(text.dup.force_encoding(Encoding::UTF_8))
      URI.encode_www_form(pairs.map { |key, value| [key, redact_value(key, value)] })
    end

    def redact_fields(value)
      raise Error, "a JSON body that is not an object: redact it by hand" unless value.is_a?(Hash)

      value.to_h { |key, field| [key, redact_value(key, field)] }
    end

    def redact_value(key, value)
      return value if value.nil? || value == ""

      if PHONE_FIELDS.include?(key) then phone(value)
      elsif TEXT_FIELDS.include?(key) then text(key, value)
      elsif ID_FIELDS.include?(key) then fake_id(value)
      elsif ACCOUNT_FIELDS.key?(key) then value.is_a?(String) ? ACCOUNT_FIELDS[key].to_s : ACCOUNT_FIELDS[key]
      elsif KEPT_FIELDS.include?(key) then value
      else unknown(key, value)
      end
    end

    # Equal numbers stay equal (e.g. "sms" and "from"), so which fields carry
    # the same number is still visible.
    def phone(value)
      number = @phones[value.to_s] ||= TEST_NUMBERS.fetch(@phones.size % TEST_NUMBERS.size)
      return number if value.is_a?(String)

      @notes << "a phone field holds a #{value.class}"
      value.is_a?(Integer) ? Integer(number.delete_prefix("+"), 10) : REDACTED
    end

    def text(key, value)
      return value unless value.is_a?(String)

      if value.match?(%r{\Ahttps?://}i)
        @notes << "#{key} is a URL (inbound MMS?)"
        return "https://example.invalid/redacted-media"
      end
      @texts[value] ||= "redacted text #{@texts.size + 1}"
    end

    def fake_id(value)
      return value unless value.is_a?(String)

      @ids[value] ||= value.gsub(/[A-Za-z0-9]/, ((@ids.size % 9) + 1).to_s)
    end

    def unknown(key, value)
      @notes << "kept unknown field #{key.inspect} (#{value.class}); check its value"
      return value unless value.is_a?(String)

      value.gsub(/\+?\d[\d ()-]{6,}\d/) do |match|
        @notes << "replaced a number-like value in #{key.inspect}"
        match.start_with?("+") ? TEST_NUMBERS.first : REDACTED
      end
    end

    def redact_header(name, value, body)
      return body.bytesize.to_s if name.casecmp?("content-length")
      return value if KEPT_HEADERS.include?(name.downcase)

      @notes << "header #{name} kept by name only"
      REDACTED
    end
  end

  module_function

  def redact(input, output)
    redactor = Redactor.new
    File.write(output, redactor.redact(File.binread(input)))
    redactor.notes.uniq
  end
end

if $PROGRAM_NAME == __FILE__
  command, *args = ARGV
  case command
  when "serve"
    secret = ENV.fetch("CLICKSEND_CAPTURE_SECRET") { abort "Set CLICKSEND_CAPTURE_SECRET (e.g. `ruby -rsecurerandom -e 'puts SecureRandom.urlsafe_base64(24)'`)" }
    server = WebhookCapture::Server.new(secret: secret, port: Integer(args[0] || 9292), dir: args[1] || "tmp/webhook-captures",
      status: ENV.fetch("CAPTURE_STATUS", "200 OK"))
    puts "listening on 127.0.0.1:#{server.port}; point the tunnel here and the rule at https://<tunnel>/<secret>/<name>"
    server.run
  when "redact"
    abort "usage: ruby script/webhook_capture.rb redact CAPTURE.http FIXTURE.http" unless args.size == 2
    notes = WebhookCapture.redact(*args)
    puts "wrote #{args[1]}"
    notes.each { |note| puts "check: #{note}" }
  else
    abort "usage: ruby script/webhook_capture.rb serve [PORT] [DIR] | redact CAPTURE.http FIXTURE.http"
  end
end
