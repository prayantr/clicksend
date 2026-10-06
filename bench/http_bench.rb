# frozen_string_literal: true

# Benchmarks the default Net::HTTP adapter against net_http_persistent through
# the whole client (Clicksend::Client#sms.deliver: JSON encode, Faraday, HTTP,
# JSON parse, result objects), against a local keep-alive server running in a
# separate process.
#
#   BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bench/http_bench.rb [--quick] [--json PATH]
#
# Methodology and limits: research/1.2-observability-and-http.md.

require "clicksend"
require "faraday/net_http_persistent"
require "json"
require "tmpdir"
require "fileutils"
require_relative "support/keep_alive_server"

QUICK = ARGV.include?("--quick")
JSON_PATH = (ARGV[ARGV.index("--json") + 1] if ARGV.include?("--json"))
CERT_DIR = Dir.mktmpdir("clicksend-bench-certs")
at_exit { FileUtils.remove_entry(CERT_DIR) }
TestCertificates.trust_ca!(CERT_DIR)

ADAPTERS = {
  "net_http (default)" => nil,
  "net_http_persistent" => :persistent # pool_size set per scenario
}.freeze

# The server runs in a child process so its threads and allocations are not
# counted against the client. Commands go over a pipe.
class ServerProcess
  attr_reader :port

  def initialize(**options)
    commands, @commands = IO.pipe
    @replies, replies = IO.pipe
    @pid = fork do
      @commands.close
      @replies.close
      options[:tls] = TestCertificates.server_context if options.delete(:tls)
      server = KeepAliveServer.new(**options)
      replies.puts(server.port)
      while (command = commands.gets)
        case command.strip
        when "stats" then replies.puts(JSON.generate(server.stats))
        when "stop" then break
        end
      end
      exit!(0)
    end
    commands.close
    replies.close
    @port = Integer(@replies.gets)
  end

  def stats
    @commands.puts("stats")
    JSON.parse(@replies.gets, symbolize_names: true)
  end

  def stop
    @commands.puts("stop")
    Process.wait(@pid)
  end
end

def client_for(server, tls:, adapter:, pool_size:)
  adapter = [:net_http_persistent, {pool_size: pool_size}] if adapter == :persistent
  Clicksend::Client.new(username: "u", api_key: "k", base_url: "#{tls ? "https" : "http"}://127.0.0.1:#{server.port}",
    adapter: adapter, max_retries: 0, timeout: 10, open_timeout: 5)
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def percentile(sorted, fraction)
  sorted[[(sorted.size * fraction).ceil - 1, 0].max]
end

# TCP sockets this process holds to the server, by state, from lsof.
# (What happens to them afterwards is measured by bench/cleanup_probe.rb:
# here the client may still be referenced from the stack.)
def client_sockets(port)
  out = `lsof -nP -a -p #{Process.pid} -iTCP:#{port} 2>/dev/null`
  out.lines.drop(1).map { |line| line[/\((\w+)\)\s*\z/, 1] }.tally
end

def run(label, tls:, rtt:, adapter:, threads:, requests:, clients: 1, pool_size: threads, with_per_call: false)
  server = ServerProcess.new(tls: tls, rtt: rtt, idle_timeout: 30)
  shared = Array.new(clients) { client_for(server, tls: tls, adapter: adapter, pool_size: pool_size) }
  deliver = lambda do |client|
    client = client.with(timeout: 10) if with_per_call
    client.sms.deliver(to: "+61411111111", body: "hello").status
  end
  deliver.call(shared.first) if clients == 1 && !with_per_call # warm-up (and one connection) excluded below
  before = server.stats
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  per_thread = requests / threads
  errors = Queue.new
  started = now
  latencies = Array.new(threads) { |t|
    Thread.new do
      client = shared[t % clients]
      Array.new(per_thread) {
        begin
          t0 = now
          deliver.call(client)
          now - t0
        rescue Clicksend::Error => e
          errors << "#{e.class.name}#{" (ambiguous)" if e.ambiguous?}"
          nil
        end
      }.compact
    end
  }.flat_map(&:value).sort
  elapsed = now - started
  allocations = (GC.stat(:total_allocated_objects) - allocated) / latencies.size.to_f
  after = server.stats
  sockets_open = client_sockets(server.port)
  server.stop
  {
    scenario: label, tls: tls, rtt_ms: (rtt * 1000).round, adapter: adapter ? "net_http_persistent(pool #{pool_size})" : "net_http",
    threads: threads, clients: clients, requests: latencies.size,
    errors: Array.new(errors.size) { errors.pop }.tally,
    req_per_s: (latencies.size / elapsed).round(1),
    p50_ms: (percentile(latencies, 0.50) * 1000).round(2),
    p95_ms: (percentile(latencies, 0.95) * 1000).round(2),
    allocs_per_req: (threads == 1) ? allocations.round : nil,
    connections_opened: after[:accepts] - before[:accepts],
    client_sockets_open: sockets_open.sum { |_, count| count }
  }
end

scale = QUICK ? 0.2 : 1.0
n = ->(count) { [(count * scale).round, 8].max }
results = []
[false, true].each do |tls|
  ADAPTERS.each_value do |adapter|
    results << run("localhost, 1 thread", tls: tls, rtt: 0, adapter: adapter, threads: 1, requests: n.call(1000))
    results << run("localhost, 8 threads, 1 client", tls: tls, rtt: 0, adapter: adapter, threads: 8, requests: n.call(2000))
    results << run("25ms RTT, 1 thread", tls: tls, rtt: 0.025, adapter: adapter, threads: 1, requests: n.call(80))
    results << run("25ms RTT, 8 threads, 1 client", tls: tls, rtt: 0.025, adapter: adapter, threads: 8, requests: n.call(400))
  end
end
results << run("localhost, 4 clients x 1 thread", tls: true, rtt: 0, adapter: :persistent, threads: 4, clients: 4, pool_size: 1, requests: n.call(800))
results << run("localhost, 8 threads, pool_size 2", tls: true, rtt: 0, adapter: :persistent, threads: 8, pool_size: 2, requests: n.call(800))
results << run("25ms RTT, 8 threads, pool_size 2", tls: true, rtt: 0.025, adapter: :persistent, threads: 8, pool_size: 2, requests: n.call(400))
results << run("localhost, client.with per call", tls: true, rtt: 0, adapter: :persistent, threads: 1, requests: n.call(200), with_per_call: true)

columns = %i[scenario tls rtt_ms adapter threads requests errors req_per_s p50_ms p95_ms allocs_per_req connections_opened client_sockets_open]
puts "| #{columns.join(" | ")} |"
puts "|#{columns.map { "---" }.join("|")}|"
results.each { |row| puts "| #{columns.map { |c| row[c].inspect.delete('"') }.join(" | ")} |" }
File.write(JSON_PATH, JSON.pretty_generate(results)) if JSON_PATH
