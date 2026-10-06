# frozen_string_literal: true

require "socket"
require "zlib"

# More real-socket checks of send safety (Net::HTTP + Faraday + transport +
# connection): malformed HTTP from the server, a TLS handshake that never
# completes, Retry-After over the wire, and a client shared by many threads.
# Each connection is answered by the next handler (the last one repeats);
# +arrivals+ counts requests that were fully received.
class WireServer
  attr_reader :arrivals

  def initialize(*handlers)
    @handlers = handlers
    @arrivals = []
    @lock = Mutex.new
    @count = 0
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
  end

  def port = @server.addr[1]

  def stop
    @thread.kill
    @server.close
  end

  # Reads one request and returns its body.
  def receive(socket)
    head = +""
    head << socket.readpartial(4096) until head.include?("\r\n\r\n")
    header, body = head.split("\r\n\r\n", 2)
    length = header[/^content-length:\s*(\d+)/i, 1].to_i
    body << socket.readpartial(4096) while body.bytesize < length
    @lock.synchronize { @arrivals << body }
    body
  end

  private

  def serve
    loop do
      socket = @server.accept
      handler = @lock.synchronize { @handlers[(@count += 1) - 1] || @handlers.last }
      Thread.new(socket) do |s|
        handler.call(s, self)
      rescue IOError, SystemCallError
        nil
      ensure
        s.close unless s.closed?
      end
    end
  end
end

WIRE_SEND_OK = '{"http_code":200,"response_code":"SUCCESS","data":{"messages":[{"message_id":"A","status":"SUCCESS"}]}}'

RSpec.describe "Send safety on the wire" do
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
    @server&.stop
  end

  before { allow(Kernel).to receive(:sleep) }

  def serve(*handlers) = (@server = WireServer.new(*handlers))

  def reply(raw) = ->(socket, server) { server.receive(socket) && socket.write(raw) }

  def ok(body = WIRE_SEND_OK) = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"

  def wire_client(scheme: "http")
    Clicksend::Client.new(username: "u", api_key: "k", base_url: "#{scheme}://127.0.0.1:#{@server.port}", max_retries: 2, timeout: 0.5, open_timeout: 0.5)
  end

  def deliver(client = wire_client, ref: nil) = client.sms.deliver(to: "+61411111111", body: "hi", custom_string: ref)

  {
    "a truncated, close-delimited 2xx body" => "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n{\"data\":{\"messages\":[{\"mess",
    "a garbage status line" => "SMTP ready\r\n\r\n",
    "a malformed chunked body" => "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\nabc\r\n0\r\n\r\n",
    "a corrupt gzip 2xx body" => "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 10\r\nConnection: close\r\n\r\n0123456789",
    "a redirect (never followed)" => "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/v3/sms/send\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    "an out-of-range status" => "HTTP/1.1 600 Odd\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    "an error inside a 2xx envelope" => "HTTP/1.1 200 OK\r\nContent-Length: 46\r\nConnection: close\r\n\r\n{\"http_code\":429,\"response_code\":\"X\",\"data\":1}"
  }.each do |label, raw|
    it "sends once and raises a Clicksend error marked ambiguous for #{label}" do
      serve(reply(raw), reply(ok))
      expect { deliver }.to raise_error(Clicksend::Error) { |e|
        expect(e).to be_ambiguous
        expect(e).not_to be_retryable
      }
      expect(@server.arrivals.size).to eq(1)
    end
  end

  it "accepts a valid gzip-encoded send result" do
    gzipped = Zlib.gzip(WIRE_SEND_OK)
    serve(reply("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: #{gzipped.bytesize}\r\nConnection: close\r\n\r\n#{gzipped}"))
    expect(deliver.status).to eq("SUCCESS")
  end

  it "retries a send whose TLS handshake never completed (an open timeout: nothing was written)" do
    serve(->(_socket, _server) { sleep 1.2 })
    expect { deliver(wire_client(scheme: "https")) }.to raise_error(Clicksend::TimeoutError) { |e|
      expect(e.request_may_have_been_sent?).to be(false)
      expect(e).not_to be_ambiguous
      expect(e.request.attempts).to eq(3)
    }
    expect(@server.arrivals).to be_empty
  end

  it "retries a 429 whose Retry-After HTTP-date is already past" do
    serve(reply("HTTP/1.1 429 Too Many\r\nRetry-After: Wed, 21 Oct 2015 07:28:00 GMT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), reply(ok))
    expect(deliver.status).to eq("SUCCESS")
    expect(@server.arrivals.size).to eq(2)
  end

  it "does not wait for a Retry-After beyond the policy's limit" do
    serve(reply("HTTP/1.1 429 Too Many\r\nRetry-After: 99999999999999999999\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
    expect { deliver }.to raise_error(Clicksend::RateLimitError) { |e| expect(e.request.attempts).to eq(1) }
  end

  it "keeps every send to one arrival when a shared client sends from many threads with mixed failures" do
    kinds = %w[ok reset close s503 s429 garbage]
    served = Hash.new(0)
    lock = Mutex.new
    serve(lambda do |socket, server|
      ref = JSON.parse(server.receive(socket))["messages"][0]["custom_string"]
      kind = ref.split(":").first
      first = lock.synchronize { (served[ref] += 1) == 1 }
      case kind
      when "ok" then socket.write(ok(WIRE_SEND_OK.sub('"A"', JSON.generate(ref))))
      when "reset" then socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, [1, 0].pack("ii"))
      when "close" then nil
      when "s503" then socket.write("HTTP/1.1 503 X\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      when "s429" then socket.write(first ? "HTTP/1.1 429 X\r\nRetry-After: 0\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" : ok)
      when "garbage" then socket.write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n{nope")
      end
    end)
    client = wire_client
    results = Queue.new
    Array.new(12) { |t|
      Thread.new do
        kinds.size.times do |i|
          ref = "#{kinds[(t + i) % kinds.size]}:#{t}:#{i}"
          results << [ref, deliver(client, ref: ref)]
        rescue Clicksend::Error => e
          results << [ref, e]
        end
      end
    }.each(&:join)

    outcomes = Array.new(results.size) { results.pop }
    expect(outcomes.size).to eq(72)
    outcomes.each do |ref, outcome|
      kind = ref.split(":").first
      expect(served[ref]).to eq((kind == "s429") ? 2 : 1), ref
      if %w[ok s429].include?(kind)
        expect(outcome).to be_a(Clicksend::SMS::Message), ref
      else
        expect(outcome).to be_ambiguous, ref
        expect(outcome.request.attempts).to eq(1), ref
      end
      expect(outcome.message_id).to eq(ref) if kind == "ok"
    end
  end
end
