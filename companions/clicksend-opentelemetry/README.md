# clicksend-opentelemetry (prototype, 1.2 spike)

OpenTelemetry spans for [clicksend](../../README.md), built on its public
`instrumenter:` hook. Depends on `opentelemetry-api` only; your application
chooses the SDK and exporter.

```ruby
# Gemfile
gem "clicksend-opentelemetry"

# config/initializers/clicksend.rb
require "clicksend/opentelemetry"
CLICKSEND = Clicksend::Client.new(instrumenter: Clicksend::OpenTelemetry::Instrumenter.new)

# Keeping ActiveSupport::Notifications subscribers as well (the OpenTelemetry one last):
CLICKSEND = Clicksend::Client.new(
  instrumenter: Clicksend::OpenTelemetry::FanOut.new(ActiveSupport::Notifications, Clicksend::OpenTelemetry::Instrumenter.new)
)
```

Pass `base_url:` to the instrumenter too if the client does not use the default
`https://rest.clicksend.com` (the instrumentation payload has no host).
`record_path: false` leaves out `url.path`.

## What is recorded

One span per API call, retries included: kind CLIENT, named `clicksend <operation>`
(e.g. `clicksend sms.deliver`), or `clicksend <METHOD>` for `client.request` without `operation:`.

| Attribute | From |
|---|---|
| `http.request.method`, `url.path`, `server.address`, `server.port` | the call |
| `http.response.status_code` | the last response, if any |
| `error.type`, span status ERROR, an `exception` event | a failed call: class, HTTP status, ClickSend `response_code` and request line only, never the exception message |
| `clicksend.operation`, `clicksend.idempotent`, `clicksend.attempts`, `clicksend.ambiguous`, `clicksend.response_code` | the request.clicksend payload |

Each retry adds a `clicksend.retry` event (`clicksend.retry.attempt`, `clicksend.retry.delay`
in seconds, `error.type`, `http.response.status_code`).

Never recorded: phone numbers, message text, request or response bodies, query strings,
headers, credentials.

A per-message rejection (`Clicksend::MessageRejected`) is decided after the HTTP call
succeeded, so its span is not an error.

## With HTTP-level instrumentation

With `opentelemetry-instrumentation-faraday`, each HTTP attempt is a child CLIENT span
(Net::HTTP's own span is then suppressed); with only `-net_http`, each attempt is a
`GET`/`POST` span plus a `connect` span. **Those spans record the query string**
(`url.full` / `url.query`): `sms.history(to:)` puts the phone number in them. Their
instrumentation also sends a `traceparent` header to ClickSend.

## Guarantees

The instrumenter never changes a call's outcome: its own failures go to
`OpenTelemetry.handle_error`, the request runs exactly once, and errors (including
ambiguity) pass through unchanged. `spec/` proves this with a failing tracer, a send
timeout and a real local server.

```sh
BUNDLE_GEMFILE=companions/clicksend-opentelemetry/Gemfile bundle install
cd companions/clicksend-opentelemetry && bundle exec rspec
```
