# frozen_string_literal: true

# Two questions the throughput benchmark cannot answer:
#
# 1. Cleanup: what happens to pooled sockets when the server closes an idle
#    connection, and when clients are discarded (no Client#close exists)?
# 2. The keep-alive race: how often does reusing a connection that the server
#    is closing turn a send into an ambiguous error?
#
#   BUNDLE_GEMFILE=bench/Gemfile bundle exec ruby bench/cleanup_and_race.rb
#
# The server runs in this process (threads), so these are not timings.

require "clicksend"
require "faraday/net_http_persistent"
require "tmpdir"
require "fileutils"
require_relative "support/keep_alive_server"

CERT_DIR = Dir.mktmpdir("clicksend-bench-certs")
at_exit { FileUtils.remove_entry(CERT_DIR) }
TestCertificates.trust_ca!(CERT_DIR)
PERSISTENT = [:net_http_persistent, {pool_size: 4}].freeze

def client_for(server, adapter: PERSISTENT, scheme: "https")
  Clicksend::Client.new(username: "u", api_key: "k", base_url: "#{scheme}://127.0.0.1:#{server.port}", adapter: adapter,
    max_retries: 0, timeout: 5)
end

# Client-side sockets only (the server runs in this process too).
def lsof(port)
  `lsof -nP -a -p #{Process.pid} -iTCP:#{port} 2>/dev/null`.lines.drop(1)
    .select { |line| line.include?("->127.0.0.1:#{port} ") }
    .map { |line| line[/\((\w+)\)\s*\z/, 1] }.tally
end

def deliver(client)
  client.sms.deliver(to: "+61411111111", body: "hello")
end

# Builds, uses and drops clients in its own frame, so nothing on the caller's
# stack still points at them when the GC runs.
def use_and_drop_clients(server, count, adapter)
  count.times { deliver(client_for(server, adapter: adapter)) }
  nil
end

puts "## 1. Cleanup (TLS)"
server = KeepAliveServer.new(tls: TestCertificates.server_context, idle_timeout: 0.5)
client = client_for(server)
deliver(client)
puts "after one request:                     client #{lsof(server.port)}, server open #{server.open_connections}"
sleep 1.0
puts "server closed it after 0.5s idle:      client #{lsof(server.port)}, server open #{server.open_connections}"
deliver(client)
puts "next request (replaced, not retried):  client #{lsof(server.port)}, server open #{server.open_connections}, accepts #{server.accepts}, requests #{server.requests.size}"
server.stop

{"net_http (default)" => nil, "net_http_persistent" => PERSISTENT}.each do |name, adapter|
  server = KeepAliveServer.new(tls: TestCertificates.server_context)
  use_and_drop_clients(server, 20, adapter)
  before = lsof(server.port)
  3.times { GC.start }
  sleep 0.3
  puts "#{name}: 20 clients used once then dropped: client sockets #{before} -> after GC #{lsof(server.port)}; " \
    "server open #{server.open_connections}"
  server.stop
end

puts
puts "## 2. Keep-alive race (plain HTTP)"
puts "server closes connections idle for 0.2s; a request arriving in the next 20ms is discarded unread (RST),"
puts "as when its FIN is still in flight. 150 sends per row."
[
  ["net_http (default)", nil, 0.15..0.25],
  ["net_http_persistent", PERSISTENT, 0.15..0.25],
  ["net_http_persistent", PERSISTENT, 0.0..0.15]
].each do |name, adapter, gaps|
  server = KeepAliveServer.new(idle_timeout: 0.2, close_delay: 0.02)
  client = client_for(server, adapter: adapter, scheme: "http")
  random = Random.new(42)
  outcomes = Hash.new(0)
  150.times do
    sleep random.rand(gaps)
    deliver(client)
    outcomes["sent"] += 1
  rescue Clicksend::Error => e
    outcomes["#{e.class.name}#{" ambiguous" if e.ambiguous?}"] += 1
  end
  stats = server.stats
  puts "#{name}, gaps #{gaps}: #{outcomes} | server received #{stats[:requests]}, discarded unread #{stats[:discarded]}, connections #{stats[:accepts]}"
  server.stop
end
