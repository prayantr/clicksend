# frozen_string_literal: true

require "json"
require "yaml"
require "rack"
require "rack/mock_request"

# Replays the webhook fixtures in spec/fixtures/webhooks through Rack's own
# request parsing, so a spec sees exactly the params an app would hand to
# Clicksend::Webhook (Rack's form decoder, its UTF-8 tagging, last-wins for
# repeated keys, nested "a[b]" keys), not a hand-built Hash.
#
# A fixture is one request, in one of these files:
#   *.form   a form body, sent as a POST with Content-Type application/x-www-form-urlencoded
#            (ClickSend's default for inbound rules, and its receipt format per archived docs)
#   *.query  a query string, sent as a GET (an inbound rule with webhook_type "get")
#   *.json   a JSON body, sent as a POST with Content-Type application/json
#            (webhook_type "json"; the real Content-Type is not yet known)
#   *.http   a raw HTTP request as captured (request line, headers, blank line, body);
#            the method and Content-Type decide how it is decoded
#
# manifest.yml says what each fixture is, where its shape comes from, and what
# parsing it must produce. See spec/fixtures/webhooks/README.md.
module WebhookReplay
  DIR = File.expand_path("../fixtures/webhooks", __dir__)
  MANIFEST = File.join(DIR, "manifest.yml")
  PATH = "/clicksend/:secret/webhook"

  Capture = Data.define(:file, :http_method, :target, :headers, :body) do
    def content_type
      headers.find { |name, _| name.casecmp?("content-type") }&.last
    end
  end

  module_function

  def manifest
    YAML.safe_load_file(MANIFEST).fetch("fixtures")
  end

  def load(relative)
    file = File.join(DIR, relative)
    text = File.binread(file)
    case File.extname(file)
    when ".form" then Capture.new(relative, "POST", PATH, {"Content-Type" => "application/x-www-form-urlencoded"}, text.chomp)
    when ".json" then Capture.new(relative, "POST", PATH, {"Content-Type" => "application/json"}, text)
    when ".query" then Capture.new(relative, "GET", "#{PATH}?#{text.chomp}", {}, "")
    when ".http" then parse_http(relative, text)
    else raise ArgumentError, "unknown webhook fixture type: #{relative}"
    end
  end

  # A raw request: "METHOD target HTTP/1.1", header lines, a blank line, the
  # body. Line endings may be CRLF or LF (fixtures are edited by hand); the
  # body is kept byte for byte, minus one trailing newline added by editors.
  def parse_http(relative, text)
    head, body = text.split(/\r?\n\r?\n/, 2)
    request_line, *header_lines = head.split(/\r?\n/)
    http_method, target, = request_line.split(" ")
    headers = header_lines.to_h { |line| line.split(":", 2).map(&:strip) }
    Capture.new(relative, http_method, target, headers, body.to_s.delete_suffix("\n"))
  end

  def rack_request(capture)
    options = {method: capture.http_method, input: capture.body}
    options["CONTENT_TYPE"] = capture.content_type if capture.content_type
    Rack::Request.new(Rack::MockRequest.env_for(capture.target, options))
  end

  # The params a Rack app would pass to Clicksend::Webhook: the query string
  # for a GET, the parsed JSON for a JSON body, and Rack's form params
  # otherwise. (Rails' request.request_parameters gives the same Hash for a
  # form or JSON POST, plus ParamsWrapper's nested copy for JSON; see
  # #rails_request_parameters.)
  def params(capture)
    request = rack_request(capture)
    if request.get?
      request.GET
    elsif request.media_type == "application/json"
      JSON.parse(request.body.read)
    else
      request.POST
    end
  end

  # What a default Rails app's request.request_parameters holds for a JSON
  # push: ParamsWrapper (on for JSON in new apps) merges a nested copy of the
  # body under the controller's name.
  def rails_request_parameters(capture, wrapper_key: "clicksend_webhook")
    body = params(capture)
    return body unless rack_request(capture).media_type == "application/json"

    body.merge(wrapper_key => body)
  end
end
