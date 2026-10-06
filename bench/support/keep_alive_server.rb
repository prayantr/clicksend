# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

# A small HTTP/1.1 server on 127.0.0.1 that keeps connections alive, for the
# persistent-connection spike (bench/spec and bench/http_bench.rb).
#
# Unlike spec/support/local_server.rb (one request per connection), it serves
# many requests per connection and can misbehave on any one of them, so the
# client's handling of reused connections can be tested on real sockets.
#
# * tls: an OpenSSL::SSL::SSLContext to serve HTTPS (see TestCertificates)
# * idle_timeout: seconds after which an idle keep-alive connection is closed
#   (like a real server's keep-alive timeout); nil keeps it open
# * rtt: simulated network round trip, in seconds. Each response is delayed
#   by one rtt, and each new connection by +handshake_rtts+ (default: 1 for
#   TCP, 2 for TCP + TLS 1.3) before the TLS handshake or first read. This
#   models latency on the server side only; see research/1.2-observability-and-http.md.
# * close_delay: with idle_timeout, how long the connection stays open after
#   the server decided to close it, while anything the client sends is
#   discarded unread. Models the FIN still being in flight (one-way delay)
#   when the client reuses the connection: the keep-alive race.
# * behaviour: called with each Request; returns what to do with it:
#     :ok        respond (keep-alive)
#     :ok_close  respond with "Connection: close", then close
#     :close     the request was received; close without responding (FIN)
#     :reset     the request was received; reset the connection (RST)
#     :hang      respond only after +hang+ seconds
#
# Records every connection accepted and every request fully received.
class KeepAliveServer
  Request = Data.define(:connection, :index, :http_method, :path) do
    def to_s
      "#{http_method} #{path}"
    end
  end

  FIXTURES = File.expand_path("../../spec/fixtures", __dir__)
  BODIES = {
    "/v3/sms/send" => File.read(File.join(FIXTURES, "sms_send.json")),
    "/v3/account" => File.read(File.join(FIXTURES, "account.json"))
  }.freeze

  attr_reader :port

  def initialize(tls: nil, idle_timeout: nil, close_delay: 0, rtt: 0, handshake_rtts: nil, hang: 1.0, behaviour: nil)
    @tls = tls
    @idle_timeout = idle_timeout
    @close_delay = close_delay
    @discarded = 0
    @rtt = rtt
    @handshake_rtts = handshake_rtts || (tls ? 2 : 1)
    @hang = hang
    @behaviour = behaviour || ->(_request) { :ok }
    @lock = Mutex.new
    @requests = []
    @accepts = 0
    @open = 0
    @max_open = 0
    @sockets = []
    @server = TCPServer.new("127.0.0.1", 0)
    @server.listen(1024)
    @port = @server.addr[1]
    @acceptor = Thread.new { accept_loop }
  end

  def requests
    @lock.synchronize { @requests.dup }
  end

  def accepts
    @lock.synchronize { @accepts }
  end

  def open_connections
    @lock.synchronize { @open }
  end

  def stats
    @lock.synchronize { {accepts: @accepts, requests: @requests.size, open: @open, max_open: @max_open, discarded: @discarded} }
  end

  def stop
    @acceptor.kill
    @server.close
    @lock.synchronize { @sockets.dup }.each do |socket|
      socket.close
    rescue IOError, SystemCallError
      nil
    end
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      connection = @lock.synchronize do
        @accepts += 1
        @open += 1
        @max_open = [@max_open, @open].max
        @sockets << socket
        @accepts - 1
      end
      Thread.new { serve(socket, connection) }
    end
  rescue IOError, SystemCallError
    nil # stopped
  end

  def serve(tcp, connection)
    sleep(@rtt * @handshake_rtts) if @rtt.positive?
    io = tcp
    if @tls
      io = OpenSSL::SSL::SSLSocket.new(tcp, @tls)
      io.sync_close = true
      io.accept
    end
    buffer = +""
    index = 0
    while (request = read_request(io, tcp, buffer, connection, index))
      @lock.synchronize { @requests << request }
      case @behaviour.call(request)
      when :ok then respond(io, request)
      when :ok_close then break respond(io, request, close: true)
      when :close then break
      when :reset then break tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      when :hang
        sleep @hang
        respond(io, request)
      end
      index += 1
    end
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil # the client went away or failed the handshake
  ensure
    begin
      io&.close
      tcp.close unless tcp.closed?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end
    @lock.synchronize do
      @open -= 1
      @sockets.delete(tcp)
    end
  end

  # nil when the client closed the connection or it sat idle too long.
  def read_request(io, tcp, buffer, connection, index)
    until buffer.include?("\r\n\r\n")
      return unless readable?(io, tcp)

      buffer << io.readpartial(16_384)
    end
    head, rest = buffer.split("\r\n\r\n", 2)
    rest = +(rest || "")
    length = head[/^content-length:\s*(\d+)/i, 1].to_i
    rest << io.readpartial(16_384) while rest.bytesize < length
    buffer.replace(rest.byteslice(length..))
    http_method, target = head.lines.first.split(" ", 3)
    Request.new(connection: connection, index: index, http_method: http_method, path: target.split("?", 2).first)
  rescue EOFError
    nil
  end

  def readable?(io, tcp)
    return true if io.respond_to?(:pending) && io.pending.positive?
    return true if tcp.wait_readable(@idle_timeout)

    if @close_delay.positive?
      sleep @close_delay
      @lock.synchronize { @discarded += 1 } if tcp.wait_readable(0)
    end
    false
  end

  def respond(io, request, close: false)
    sleep @rtt if @rtt.positive?
    body = BODIES.fetch(request.path) do
      JSON.generate("http_code" => 200, "response_code" => "SUCCESS", "response_msg" => "ok",
        "data" => {"path" => request.path, "connection" => request.connection, "index" => request.index})
    end
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
      "Connection: #{close ? "close" : "keep-alive"}\r\n\r\n#{body}")
  end
end

# A throwaway CA and server certificates for local HTTPS. The client trusts
# the CA through SSL_CERT_FILE (OpenSSL's default store reads it), exactly as
# it would trust a system CA: no verification setting is changed.
module TestCertificates
  module_function

  def key
    @key ||= OpenSSL::PKey::EC.generate("prime256v1")
  end

  def ca
    @ca ||= begin
      cert = base_cert("/CN=clicksend-spike-ca")
      extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(extensions.create_extension("keyUsage", "keyCertSign,cRLSign", true))
      cert.sign(key, "SHA256")
      cert
    end
  end

  # A certificate for +names+ (e.g. "IP:127.0.0.1"), signed by the CA, or
  # self-signed (so untrusted) with signed_by_ca: false.
  def server_context(names: "IP:127.0.0.1,DNS:localhost", signed_by_ca: true)
    issuer = signed_by_ca ? ca : nil
    cert = base_cert("/CN=#{names.split(",").first.split(":").last}")
    cert.issuer = issuer ? issuer.subject : cert.subject
    extensions = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
    cert.add_extension(extensions.create_extension("subjectAltName", names))
    cert.add_extension(extensions.create_extension("extendedKeyUsage", "serverAuth"))
    cert.sign(key, "SHA256")
    context = OpenSSL::SSL::SSLContext.new
    context.cert = cert
    context.key = key
    context
  end

  # Writes the CA to +dir+ and points OpenSSL's default store at it.
  def trust_ca!(dir)
    path = File.join(dir, "clicksend-spike-ca.pem")
    File.write(path, ca.to_pem)
    ENV["SSL_CERT_FILE"] = path
    path
  end

  def base_cert(subject)
    cert = OpenSSL::X509::Certificate.new
    cert.version = 2
    cert.serial = rand(1 << 64)
    cert.subject = OpenSSL::X509::Name.parse(subject)
    cert.issuer = cert.subject
    cert.public_key = key
    cert.not_before = Time.now - 60
    cert.not_after = Time.now + 3600
    cert
  end
end
