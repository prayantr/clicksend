# frozen_string_literal: true

# Experiment 2: a real Sidekiq process against a local stand-in for ClickSend.
#
#   redis-server --port 6399 --save "" &          # throwaway Redis
#   REDIS_URL=redis://127.0.0.1:6399/15 bundle exec ruby 02_sidekiq_semantics.rb
#
# The stand-in answers POST /v3/sms/send according to the job's custom_string:
#   "500:*"  -> HTTP 500 (ambiguous for a send: it is counted as received)
#   "429:*"  -> HTTP 429, Retry-After: 0 (not processed; not counted)
#   "slow:*" -> accepted (counted), then holds the response for SLOW seconds
#   other    -> accepted (counted), answered at once
# Nothing leaves 127.0.0.1.

require "bundler/setup"
require "socket"
require "json"
require "tmpdir"
require "sidekiq"
require "sidekiq/api"
require "clicksend"
require "clicksend/testing"

REDIS_URL = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6399/15")
# This script FLUSHes its Redis database: refuse anything but a local throwaway one.
abort "REDIS_URL must point at a throwaway local Redis" unless REDIS_URL.match?(%r{\Aredis://(127\.0\.0\.1|localhost):\d+/\d+\z})
Sidekiq.configure_client { |c| c.redis = {url: REDIS_URL} }
SLOW = 6

# ---- stand-in ClickSend ------------------------------------------------------
RECEIVED = Hash.new(0)
LOCK = Mutex.new
FAST = {on: false}
fake = Clicksend::Testing::FakeAPI.new
server = TCPServer.new("127.0.0.1", 0)
PORT = server.addr[1]
Thread.new do
  loop do
    sock = server.accept
    Thread.new(sock) do |s|
      line = s.gets
      headers = {}
      while (h = s.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.downcase] = v.strip
      end
      body = s.read(headers["content-length"].to_i)
      ref = JSON.parse(body)["messages"][0]["custom_string"]
      mode = ref.split(":").first
      if mode == "429"
        s.write "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 0\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n"
        s.write({http_code: 429, response_code: "TOO_MANY_REQUESTS", response_msg: "x"}.to_json)
      else
        LOCK.synchronize { RECEIVED[ref] += 1 }
        if mode == "500"
          payload = {http_code: 500, response_code: "INTERNAL_SERVER_ERROR", response_msg: "x"}.to_json
          s.write "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
        else
          sleep SLOW if mode == "slow" && !FAST[:on]
          r = fake.call(:post, line.split[1], body: body, headers: {})
          s.write "HTTP/1.1 #{r.status} OK\r\nContent-Type: application/json\r\nContent-Length: #{r.body.bytesize}\r\nConnection: close\r\n\r\n#{r.body}"
        end
      end
    rescue => e
      warn "server: #{e.class}: #{e.message}"
    ensure
      begin
        s.close
      rescue
        nil
      end
    end
  end
end

# ---- helpers ------------------------------------------------------------------
def redis(*cmd) = Sidekiq.redis { |c| c.call(*cmd) }

def start_sidekiq(client_timeout: 30, shutdown_timeout: 2)
  env = {"CLICKSEND_TEST_URL" => "http://127.0.0.1:#{PORT}", "CLIENT_TIMEOUT" => client_timeout.to_s, "REDIS_URL" => REDIS_URL}
  Process.spawn(env, "bundle", "exec", "sidekiq", "-r", File.expand_path("sidekiq_jobs.rb", __dir__),
    "-c", "1", "-t", shutdown_timeout.to_s, "-q", "default", out: File::NULL, err: File.join(Dir.tmpdir, "clicksend-experiment-sidekiq.log"))
end

def stop_sidekiq(pid)
  Process.kill("TERM", pid)
  Process.wait(pid)
end

def wait_until(limit = 45)
  deadline = Time.now + limit
  sleep 0.1 until yield || Time.now > deadline
end

def push(klass, ref) = Sidekiq::Client.push("class" => klass, "args" => [ref], "queue" => "default")

def push_aj(ref)
  # Same payload Sidekiq's ActiveJob adapter builds.
  job = {"job_class" => "AjRetryOnJob", "job_id" => SecureRandom.uuid, "provider_job_id" => nil, "queue_name" => "default",
         "priority" => nil, "arguments" => [ref], "executions" => 0, "exception_executions" => {}, "locale" => "en",
         "timezone" => nil, "enqueued_at" => Time.now.utc.iso8601(9), "scheduled_at" => nil}
  Sidekiq::Client.push("class" => "Sidekiq::ActiveJob::Wrapper", "wrapped" => "AjRetryOnJob", "args" => [job], "queue" => "default")
end

def report(label, ref)
  retry_set = Sidekiq::RetrySet.new.select { |j| j.args.to_s.include?(ref) }
  dead = Sidekiq::DeadSet.new.select { |j| j.args.to_s.include?(ref) }
  puts format("%-58s received=%d retry_set=%d dead_set=%d", label, RECEIVED[ref], retry_set.size, dead.size)
end

redis("FLUSHDB")
puts "Sidekiq #{Sidekiq::VERSION}, clicksend #{Clicksend::VERSION}, stand-in on 127.0.0.1:#{PORT}"

# ---- retry semantics ---------------------------------------------------------------
pid = start_sidekiq
push("PlainSendJob", "500:plain")
push("DiscardAmbiguousJob", "500:discard")
push("KillAmbiguousJob", "500:kill")
push("RecipeSendJob", "500:recipe")
push_aj("500:aj")
push_aj("429:aj")
wait_until { Sidekiq::Queue.new("default").size.zero? && Sidekiq::Workers.new.size.zero? && RECEIVED["500:aj"] >= 2 }
sleep 1
stop_sidekiq(pid)
report("Sidekiq::Job, default retry, ambiguous 500", "500:plain")
report("sidekiq_retry_in -> :discard on ambiguity", "500:discard")
report("sidekiq_retry_in -> :kill on ambiguity", "500:kill")
report("README recipe (rescue inside perform)", "500:recipe")
report("ActiveJob retry_on attempts:2 on Sidekiq, ambiguous 500", "500:aj")
report("ActiveJob retry_on attempts:2 on Sidekiq, 429", "429:aj")
puts "notes: #{redis("LRANGE", "notes", 0, -1).inspect}"
aj_retry = Sidekiq::RetrySet.new.find { |j| j.args.to_s.include?("500:aj") }
puts "AJ job in Sidekiq RetrySet: class=#{aj_retry&.klass} wrapped=#{aj_retry&.item&.dig("wrapped")} retry_count=#{aj_retry&.item&.dig("retry_count")}"

# ---- shutdown requeue -----------------------------------------------------------------
[[30, "client timeout 30s > Sidekiq -t 2"], [1, "client timeout 1s < Sidekiq -t 2"]].each do |client_timeout, label|
  redis("FLUSHDB")
  ref = "slow:#{client_timeout}"
  FAST[:on] = false
  pid = start_sidekiq(client_timeout: client_timeout, shutdown_timeout: 2)
  push("RecipeSendJob", ref)
  wait_until { RECEIVED[ref] == 1 }
  sleep 0.2
  stop_sidekiq(pid) # SIGTERM while the send is in flight
  queued = Sidekiq::Queue.new("default").size
  FAST[:on] = true # the next deploy: ClickSend answers at once
  pid = start_sidekiq(client_timeout: client_timeout)
  wait_until(10) { Sidekiq::Queue.new("default").size.zero? && Sidekiq::Workers.new.size.zero? }
  sleep 1
  stop_sidekiq(pid)
  puts format("README recipe job, SIGTERM mid-send, %-32s requeued=%d received=%d notes=%s",
    label, queued, RECEIVED[ref], redis("LRANGE", "notes", 0, -1).inspect)
end
