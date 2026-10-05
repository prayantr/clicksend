# frozen_string_literal: true

# A scripted transport for Connection/Client specs that don't need real HTTP.
# Each queued entry is either a Clicksend::Transport::Response or an exception.
class FakeTransport
  Call = Data.define(:method, :path, :query, :body, :headers)

  attr_reader :calls

  def initialize(*outcomes)
    @outcomes = outcomes
    @calls = []
  end

  def self.json(status, payload, headers: {})
    body = payload.is_a?(String) ? payload : JSON.generate(payload)
    Clicksend::Transport::Response.new(status: status, headers: headers, body: body)
  end

  def call(method, path, query:, body:, headers:)
    @calls << Call.new(method, path, query, body, headers)
    outcome = @outcomes.shift or raise "FakeTransport: no response queued for #{method.upcase} #{path}"
    raise outcome if outcome.is_a?(Exception)

    outcome
  end
end

NO_RETRY = Struct.new(:max_retries) {
  def delay(**) = nil
}.new(0)
