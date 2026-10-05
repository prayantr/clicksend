# frozen_string_literal: true

module ApiHelpers
  BASE = "https://rest.clicksend.com"
  USERNAME = "test-user"
  API_KEY = "test-api-key-0000"

  def client(**options)
    Clicksend::Client.new(username: USERNAME, api_key: API_KEY, **options)
  end

  # Stubs a ClickSend call, asserting authentication and default headers.
  def stub_api(method, path, query: nil, body: nil)
    request = {basic_auth: [USERNAME, API_KEY], headers: {"Accept" => "application/json"}}
    request[:query] = query if query
    request[:body] = body if body
    stub_request(method, "#{BASE}#{path}").with(**request)
  end

  def json_response(payload, status: 200, headers: {})
    {status: status, body: payload.is_a?(String) ? payload : JSON.generate(payload), headers: {"Content-Type" => "application/json"}.merge(headers)}
  end

  def envelope(data, http_code: 200, response_code: "SUCCESS", response_msg: "OK")
    {"http_code" => http_code, "response_code" => response_code, "response_msg" => response_msg, "data" => data}
  end

  def fixture(name)
    JSON.parse(File.read(File.join(__dir__, "..", "fixtures", "#{name}.json")))
  end
end

RSpec.configure { |config| config.include ApiHelpers }
