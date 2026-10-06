# clicksend-opentelemetry

OpenTelemetry spans for the [clicksend](https://github.com/prayantr/clicksend) gem, built only on
its public `instrumenter:` hook. It depends on `opentelemetry-api`; your application chooses the
SDK and exporter.

**Optional.** `clicksend` doesn't depend on this gem or on OpenTelemetry, and works the same
without it. Add it only if you want ClickSend spans in your traces.

> It lives in the clicksend repository and is released separately from `clicksend`, on its own
> version line ([CHANGELOG](CHANGELOG.md)). While it is 0.x, a minor release may rename attributes
> as OpenTelemetry's semantic conventions change. Unofficial: not affiliated with ClickSend.

Requires Ruby 3.3 or newer, `clicksend` 1.x (1.1 or later) and `opentelemetry-api` 1.x.

## Installation

```ruby
# Gemfile
gem "clicksend-opentelemetry", "~> 0.1"
```

## Usage

```ruby
# config/initializers/clicksend.rb
require "clicksend/opentelemetry"

CLICKSEND = Clicksend::Client.new(instrumenter: Clicksend::OpenTelemetry::Instrumenter.new)
```

The instrumenter takes its tracer from the global provider when it is built. Before
`OpenTelemetry::SDK.configure` runs, that is the API's proxy, which forwards to the SDK once it is
configured, so the order of your initializers doesn't matter. Pass `tracer_provider:` to use
another provider.

To keep your `ActiveSupport::Notifications` subscribers as well, combine both with `FanOut`. Put
the OpenTelemetry instrumenter **last**: its span then covers only the request, and a subscriber
that raises after the request finished (which the client ignores) is not recorded as the span's
error.

```ruby
CLICKSEND = Clicksend::Client.new(
  instrumenter: Clicksend::OpenTelemetry::FanOut.new(ActiveSupport::Notifications, Clicksend::OpenTelemetry::Instrumenter.new)
)
```

Options:
- `base_url:` the client's `base_url`, if it isn't the default `https://rest.clicksend.com`. The
  instrumentation payload has no host, so `server.address` and `server.port` come from here.
- `record_path: false` leaves out `url.path`, and the path in the exception event's message. Paths never contain a query string, but some contain
  a message ID (`sms.receipt`, `sms.cancel`), and paths you pass to `client.request` are recorded as
  you wrote them.

## What is recorded

One span per API call, retries included: kind CLIENT, named `clicksend <operation>` (for example
`clicksend sms.deliver`), or `clicksend <METHOD>` for `client.request` without `operation:`. Paths
are never used in span names, because they can contain IDs. `sms.search_history` reads history page
by page, so it produces one `clicksend sms.history` span per page.

| Attribute | From |
|---|---|
| `http.request.method`, `url.path`, `server.address`, `server.port` | the call |
| `http.response.status_code` | the last response, if there was one |
| `error.type`, span status ERROR, an `exception` event | a failed call. The event's message is built from the class, HTTP status, ClickSend's `response_code` and the request line only, never from the exception's own message |
| `clicksend.operation`, `clicksend.idempotent`, `clicksend.attempts`, `clicksend.ambiguous`, `clicksend.response_code` | the `request.clicksend` payload |

Each retry adds a `clicksend.retry` event (`clicksend.retry.attempt`, `clicksend.retry.delay` in
seconds, `error.type`, `http.response.status_code`).

`http.request.method`, `server.*`, `url.path`, `http.response.status_code` and `error.type` are
OpenTelemetry's stable HTTP attribute names. The span describes a logical call that may span
several HTTP attempts, so it doesn't claim to be an HTTP client span: it has no `url.full`, and the
attempt count is `clicksend.attempts`, not `http.request.resend_count` (which describes one
physical request).

Never recorded: phone numbers, message text, `custom_string`, request or response bodies, query
strings, headers and credentials. The specs check the exported spans for each of these.

A message ClickSend refuses inside an HTTP 200 (`Clicksend::MessageRejected`) is detected after the
HTTP call succeeded, so its span is not an error.

## HTTP-level instrumentation records the query string

With `opentelemetry-instrumentation-faraday`, each HTTP attempt becomes a child CLIENT span of this
gem's span (Net::HTTP's own span is then suppressed). With only
`opentelemetry-instrumentation-net_http`, each attempt is a `GET`/`POST` span plus a `connect`
span. **Those spans record the query string** (`url.full` or `url.query`), and
`sms.history(to:)` and `sms.search_history` put the recipient's phone number there
(`q=to:+61...`). Those instrumentations also send a `traceparent` header to ClickSend. This gem
can't change what they record. With `opentelemetry-instrumentation-net_http` 0.29.1 and
`-faraday` 0.33.0 (checked):
- `untraced_hosts: ["rest.clicksend.com"]` on the Net::HTTP instrumentation drops its spans for
  ClickSend and keeps this gem's span;
- the Faraday instrumentation has no such option, so don't enable it in an application that
  calls history by number. `OpenTelemetry::Common::Utilities.untraced { ... }` around a call
  suppresses the Faraday span, but this gem's span too.

## Guarantees

The instrumenter never changes a call's outcome. Its own failures go to
`OpenTelemetry.handle_error`, the request runs exactly once, and errors, including ambiguous
ones, pass through unchanged. A send that times out is still a single-attempt, ambiguous
`Clicksend::TimeoutError` with tracing on. The specs show this with a failing tracer, a failing
span, a send timeout against `Clicksend::Testing::FakeAPI`, and a real local server.

## Development

The specs run against the `clicksend` in this repository (`path: "../.."` in the Gemfile), with
their own bundle:

```sh
cd companions/clicksend-opentelemetry
bundle install
bundle exec rspec
```

When the core gem's version changes, run `bundle install` here too, so `Gemfile.lock` matches it.
