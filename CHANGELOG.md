# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Planned as 1.1.0. Additive, apart from the two changes under "Changed".

### Added

- **Explicit ambiguity.** When a request that is not safe to repeat (such as an SMS send) fails
  in a way that ClickSend may still have processed, the error is extended with
  `Clicksend::AmbiguousRequestError`. That covers a timeout or reset after the request may have
  been written, a 5xx, an error reported inside a 2xx body, and an unreadable 2xx answer. The
  error keeps its class, so existing `rescue` clauses still work. `Error#ambiguous?` is the
  predicate.
- **Request context on errors and responses.** `Error#request` and `Response#request` return a
  `Clicksend::RequestInfo` with `method`, `path` (no query string), `operation` (e.g.
  `"sms.deliver"`), `idempotent` and `attempts`.
- `Error#retryable?`: whether repeating the same request later is both safe and might succeed.
- **Retry configuration.** `Clicksend::RetryPolicy` is public:
  `Client.new(retry_policy: RetryPolicy.new(max_retries:, base_delay:, max_delay:, max_retry_after:))`.
  The rule deciding *which* failures may be retried now lives in the connection and cannot be
  changed by any policy.
- **Rate limits.** `Response#rate_limit` and `APIError#rate_limit` return a `Clicksend::RateLimit`
  (`limit`, `remaining`, `reset_in`, `reset_at`) from the rate-limit headers observed live. They
  are nil when ClickSend sends none; ClickSend doesn't document these headers.
- **Instrumentation.** `Client.new(instrumenter:)` accepts `ActiveSupport::Notifications` or any
  object with the same `instrument` signature. It publishes `request.clicksend` and
  `retry.clicksend`, whose payloads never include credentials, query strings, bodies, phone
  numbers or message text. `Client#request` and `#paginate` take an optional `operation:` label.
- **Message history.** `sms.history(date_from:, date_to:, to:/from:/status:/message_id:, order:)`
  returns a page of `Clicksend::SMS::HistoryRecord`. This is the documented way to check an
  ambiguous send.
- **Webhooks.** `Clicksend::Webhook.parse_receipt`, `.parse_inbound` and `.parse` turn pushed
  receipts and replies into `SMS::Receipt` and `SMS::InboundMessage`. ClickSend doesn't sign or
  authenticate pushes, so there is deliberately no verification method; the README explains how
  to secure the endpoint.
- **Testing.** `require "clicksend/testing"` adds `Clicksend::Testing::FakeAPI`, an in-memory
  ClickSend you plug in as the transport. It records sent messages and can inject failures,
  including ambiguous ones with an explicit `processed:` flag.

### Changed

- **Mark-read without a cutoff is no longer retried.** `sms.mark_receipts_read` and
  `sms.mark_inbound_read` with no `before:` mark *everything* read at the moment ClickSend
  processes the call. Retrying after an unknown outcome could hide items that arrived in between.
  With `before:` they are still retried.
- **Error messages end with the request they came from**, e.g. `HTTP 500 (POST /v3/sms/send)`.
  Code that matched the exact message text needs updating.
- An unreadable 2xx response to a send is now marked ambiguous (it was a plain
  `MalformedResponseError`).
- `Client.new(max_retries:)` and `retry_policy:` are mutually exclusive. `Client#with` replaces
  one with the other.

### Documentation

- README: positioning, unknown send outcomes and reconciliation, webhooks, history, background
  jobs, instrumentation, and rate limits.
- API notes: a review of all 34 of ClickSend's OpenAPI sections plus the archived push
  documentation; read-only live checks of history and rate-limit headers on 2026-10-06.
- `design/1.1-audit-and-roadmap.md`: the audit, the decisions taken, and the features rejected.

## [1.0.0] - 2026-10-05

No changes to the library's behaviour or public API since 1.0.0.rc1.

### Changed

- README: installation instructions for the stable release.
- Documented that `SMS::Message#scheduled_at` mirrors ClickSend's `schedule` field, which
  ClickSend sets to the send time for an immediate message.

### Verification

- The accepted SMS send path (`POST /v3/sms/send`) was verified live against ClickSend's free
  test number, at no charge. The response was HTTP 200 with status `SUCCESS`, an upper-case UUID
  message ID, an integer `date`, `message_parts: 0` and `message_price: "0.0000"`. A regression
  spec pins this shape. Details are in [docs/clicksend-api-notes.md](docs/clicksend-api-notes.md).
- Receipt retrieval and parsing are verified against ClickSend's published examples and the
  contract specs. A live receipt was **not** observed: the test number did not generate one
  during the two-minute observation window.

## [1.0.0.rc1] - 2026-10-05

A rewrite for ClickSend's REST v3 API and modern Ruby. See [MIGRATING.md](MIGRATING.md).

### Breaking

- The Ruby namespace is now `Clicksend` (was `ClickSend`). ClickSend's official
  `clicksend_client` 6.x gem now uses `ClickSend`, and both gems must be loadable together.
- Targets ClickSend REST v3 (`https://rest.clicksend.com/v3`) instead of the legacy v2 API.
- Removed `ClickSend::REST::Client`, `#messages.send`, `#messages.receive`, `#delivery_report`,
  `#account_balance`, `ClickSend::ClickSendError` and the `use_ssl` option.
- Requires Ruby 3.3+ and Faraday 2. `multi_json` is no longer a dependency.

### Added

- `Clicksend::Client`: immutable and thread-safe, with credentials from arguments or
  `CLICKSEND_USERNAME`/`CLICKSEND_API_KEY`. Timeouts are on by default (30s read, 5s connect).
  Adds `#with` for derived clients and redacts the API key everywhere.
- `client.sms.deliver` and `client.sms.deliver_batch`. Per-message rejections inside HTTP 200
  responses raise `Clicksend::MessageRejected` for single sends and are reported by
  `Batch#rejected` for batches, which are `Enumerable` over their messages.
- Delivery receipts: `client.sms.receipts`, `#receipt`, `#mark_receipts_read`, plus
  `Receipt#delivered?`, `#failed?` and `#pending?`.
- Replies: `client.sms.inbound`, `#mark_inbound_read` and `#mark_inbound_message_read`.
- `client.account.fetch` (balance and currency). The API key that ClickSend echoes in the
  account payload (`_subaccount.api_key`) is replaced with `"[REDACTED]"` in `Account#raw`.
- `Clicksend::Page` with lazy `#auto_paging_each`.
- `client.request` and `client.paginate`, to call any ClickSend endpoint through the same
  authentication, timeouts, retries, errors and parsing. They return `Clicksend::Response`
  (`#http_status`, `#headers`, `#body`, `#data`). Paths must stay on the configured ClickSend
  origin: absolute URLs, `//host`, whitespace and control characters are rejected, and
  redirects are not followed.
- Typed error hierarchy: `ConfigurationError`, `ConnectionError`/`TimeoutError`, `APIError`
  (`BadRequestError`, `AuthenticationError`, `ForbiddenError`, `NotFoundError`,
  `RateLimitError`, `ServerError`), `MalformedResponseError` and `MessageRejected`.
- Send-safe retries. Requests ClickSend did not process (429, refused connections, DNS
  failures, connect timeouts) are retried for every method. Read timeouts, resets, TLS errors
  and 5xx responses are retried only for idempotent requests. Errors reported only inside a 2xx
  body are never retried. The gem never re-sends a message that may have reached ClickSend.
- Optional `logger:`, which never logs credentials, query strings or bodies.
- Replaceable HTTP layer (`transport:`), plus a Faraday `adapter:` option.
- Contract specs against ClickSend's published OpenAPI files, and optional live specs.

## [0.0.3] - 2014-08-21

- Last release of the original gem: send SMS, poll replies and delivery reports, and check
  the balance through ClickSend's v2 API.

[Unreleased]: https://github.com/prayantr/clicksend/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/prayantr/clicksend/compare/v1.0.0.rc1...v1.0.0
[1.0.0.rc1]: https://github.com/prayantr/clicksend/compare/c99edc5...v1.0.0.rc1
[0.0.3]: https://github.com/prayantr/clicksend/tree/c99edc5
