# frozen_string_literal: true

require "socket"

# A minimal HTTP/1.1 server on 127.0.0.1 for end-to-end tests of the real
# HTTP stack (Net::HTTP + Faraday adapter + transport + retry policy).
#
# Each accepted connection is handled by the next behaviour in the script
# (the last one repeats). It records every connection and every request that
# was fully received, so specs can assert how many times a request really
# reached the server.
class LocalServer
  RESPONSES = {
    ok: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: %<length>d\r\n\r\n%<body>s",
    unavailable: "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    rate_limited: "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  }.freeze
  OK_BODY = '{"http_code":200,"response_code":"SUCCESS","response_msg":"ok","data":{}}'

  attr_reader :requests

  def initialize(*script)
    @script = script
    @requests = []
    @connections = 0
    @lock = Mutex.new
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def port
    @server.addr[1]
  end

  def connections
    @lock.synchronize { @connections }
  end

  def stop
    @thread.kill
    @server.close
  end

  private

  def serve
    loop do
      socket = @server.accept
      index = @lock.synchronize { (@connections += 1) - 1 }
      handle(socket, @script[index] || @script.last)
    rescue IOError, SystemCallError
      # client went away; keep serving
    ensure
      socket&.close unless socket&.closed?
    end
  end

  def handle(socket, behaviour)
    if behaviour == :not_tls
      socket.readpartial(1024) # a TLS ClientHello we can't speak
      socket.write("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
      return
    end

    request = read_request(socket)
    @lock.synchronize { @requests << request }
    case behaviour
    when :close then nil # request received, connection closed without a response
    when :reset then socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii")) # close sends RST
    when :hang then sleep 2
    when :ok then socket.write(format(RESPONSES[:ok], length: OK_BODY.bytesize, body: OK_BODY))
    else socket.write(RESPONSES.fetch(behaviour))
    end
  end

  def read_request(socket)
    head = +""
    head << socket.readpartial(4096) until head.include?("\r\n\r\n")
    header, body = head.split("\r\n\r\n", 2)
    length = header[/^content-length:\s*(\d+)/i, 1].to_i
    body << socket.readpartial(4096) while body.bytesize < length
    header.lines.first.strip
  end
end
