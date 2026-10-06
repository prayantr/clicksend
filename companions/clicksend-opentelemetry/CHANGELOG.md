# Changelog

All notable changes to `clicksend-opentelemetry` are documented here. It is versioned and released
separately from [`clicksend`](https://github.com/prayantr/clicksend/blob/master/CHANGELOG.md). The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the version is 0.x, a minor
release may rename span attributes as OpenTelemetry's semantic conventions change.

## [Unreleased]

### Development

- CI also runs the suite against the oldest supported clicksend, 1.1.0 from RubyGems
  (`gemfiles/clicksend-1.1.gemfile`). An example that needs a newer clicksend declares it
  (`clicksend: ">= 1.2"`) and is skipped there with its reason; against the current clicksend
  every example must run. No change to the gem.

## [0.1.0] - 2026-10-06

The first release.

### Added

- `Clicksend::OpenTelemetry::Instrumenter`, passed to `Clicksend::Client.new(instrumenter:)`. One
  span of kind CLIENT per ClickSend API call, retries included, named `clicksend <operation>`
  (`clicksend <METHOD>` when there is no operation). Attributes: `http.request.method`,
  `server.address`, `server.port`, `url.path` (never the query string; `record_path: false` leaves
  it out, and the path out of the exception event's message), `http.response.status_code`,
  `error.type`, and `clicksend.operation`, `clicksend.idempotent`, `clicksend.attempts`,
  `clicksend.ambiguous`, `clicksend.response_code`.
  Each retry is a `clicksend.retry` span event. A failed call sets the span status to ERROR and
  adds an `exception` event whose message is built only from the class, HTTP status, ClickSend's
  `response_code` and the request line, never from the exception's own message.
- `Clicksend::OpenTelemetry::FanOut`, which sends the client's events to several instrumenters
  (for example `ActiveSupport::Notifications` and the OpenTelemetry instrumenter) while the
  request still runs once.
- The instrumenter never changes a call's outcome: its own failures go to
  `OpenTelemetry.handle_error`, the request runs exactly once, and errors, including ambiguous
  ones, pass through unchanged.
- Requires Ruby 3.3 or newer, `clicksend` 1.x (from 1.1) and `opentelemetry-api` 1.x. The SDK and
  exporters are the application's choice.

[Unreleased]: https://github.com/prayantr/clicksend/compare/clicksend-opentelemetry-v0.1.0...HEAD
[0.1.0]: https://github.com/prayantr/clicksend/releases/tag/clicksend-opentelemetry-v0.1.0
