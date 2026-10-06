# frozen_string_literal: true

require "socket"
require "openssl"
require "json"

# An HTTP/1.1 server on 127.0.0.1 that keeps connections alive, for specs of
# Client.new(adapter: :net_http_persistent) on real sockets (trimmed from the
# 1.2 persistent-connection spike).
#
# Unlike LocalServer (one request per connection), it serves many requests
# per connection and can misbehave on any one of them, so the client's
# handling of reused connections can be tested.
#
# * tls: an OpenSSL::SSL::SSLContext to serve HTTPS (see TestCertificates)
# * port: listen on this port (default: any free one)
# * idle_timeout: seconds after which an idle connection is closed
# * stall: called with each connection's index (from 0); returns seconds to
#   wait before the TLS handshake or first read (nil or 0: none)
# * behaviour: called with each Request; returns what to do with it:
#     :ok     respond (keep-alive)
#     :close  the request was received; close without responding (FIN)
#     :reset  the request was received; reset the connection (RST)
#     Numeric respond only after that many seconds
#
# Records every connection accepted and every request fully received.
class KeepAliveServer
  Request = Data.define(:connection, :index, :http_method, :path)

  FIXTURES = File.expand_path("../fixtures", __dir__)
  BODIES = {
    "/v3/sms/send" => File.read(File.join(FIXTURES, "sms_send.json")),
    "/v3/account" => File.read(File.join(FIXTURES, "account.json"))
  }.freeze

  attr_reader :port

  def initialize(tls: nil, port: 0, idle_timeout: nil, stall: nil, behaviour: nil)
    @tls = tls
    @idle_timeout = idle_timeout
    @stall = stall || ->(_connection) {}
    @behaviour = behaviour || ->(_request) { :ok }
    @lock = Mutex.new
    @requests = []
    @accepts = 0
    @sockets = []
    @server = TCPServer.new("127.0.0.1", port)
    @port = @server.addr[1]
    @acceptor = Thread.new { accept_loop }
  end

  def requests
    @lock.synchronize { @requests.dup }
  end

  def accepts
    @lock.synchronize { @accepts }
  end

  # Stops listening and closes every connection (the port then refuses).
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
        @sockets << socket
        (@accepts += 1) - 1
      end
      Thread.new { serve(socket, connection) }
    end
  rescue IOError, SystemCallError
    nil # stopped
  end

  def serve(tcp, connection)
    stall = @stall.call(connection)
    sleep(stall) if stall&.positive?
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
      action = @behaviour.call(request)
      case action
      when :close then break
      when :reset then break tcp.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      when Numeric
        sleep action
        respond(io, request)
      else respond(io, request)
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
    @lock.synchronize { @sockets.delete(tcp) }
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
    return true if io.respond_to?(:pending) && io.pending.positive? # TLS data already decrypted

    !tcp.wait_readable(@idle_timeout).nil?
  end

  def respond(io, request)
    body = BODIES.fetch(request.path) do
      JSON.generate("http_code" => 200, "response_code" => "SUCCESS", "response_msg" => "ok",
        "data" => {"path" => request.path, "connection" => request.connection, "index" => request.index})
    end
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n" \
      "Connection: keep-alive\r\n\r\n#{body}")
  end
end

# A throwaway CA and a server certificate for local HTTPS. The client trusts
# the CA through SSL_CERT_FILE (OpenSSL's default store reads it), exactly as
# it would trust a system CA: no verification setting is changed.
module TestCertificates
  module_function

  def key
    @key ||= OpenSSL::PKey::EC.generate("prime256v1")
  end

  def ca
    @ca ||= begin
      cert = base_cert("/CN=clicksend-spec-ca")
      extensions = OpenSSL::X509::ExtensionFactory.new(cert, cert)
      cert.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(extensions.create_extension("keyUsage", "keyCertSign,cRLSign", true))
      cert.sign(key, "SHA256")
      cert
    end
  end

  # A context for 127.0.0.1 signed by the CA or, with signed_by_ca: false,
  # self-signed (so untrusted).
  def server_context(signed_by_ca: true)
    issuer = signed_by_ca ? ca : nil
    cert = base_cert("/CN=127.0.0.1")
    cert.issuer = issuer ? issuer.subject : cert.subject
    extensions = OpenSSL::X509::ExtensionFactory.new(issuer || cert, cert)
    cert.add_extension(extensions.create_extension("subjectAltName", "IP:127.0.0.1"))
    cert.add_extension(extensions.create_extension("extendedKeyUsage", "serverAuth"))
    cert.sign(key, "SHA256")
    OpenSSL::SSL::SSLContext.new.tap do |context|
      context.cert = cert
      context.key = key
    end
  end

  def ca_file(dir)
    File.join(dir, "clicksend-spec-ca.pem").tap { |path| File.write(path, ca.to_pem) }
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
