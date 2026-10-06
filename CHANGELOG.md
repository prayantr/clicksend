# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Planned as 1.2.0. Additive.

### Added

- `sms.cancel(message_id)` cancels one scheduled SMS (`PUT /v3/sms/{message_id}/cancel`) and
  returns nil. ClickSend documents only the successful answer, and no idempotency, so it is not
  retried after a timeout or 5xx; such a failure is an `AmbiguousRequestError` (the message may or
  may not have been cancelled). Check `sms.history(message_id:)` for the status `"Cancelled"`
  when it matters. `PUT /v3/sms/cancel-all` is still deliberately not wrapped.
- `sms.search_history(to:, custom_string:, sent_after:, sent_before: nil)` returns the outbound
  history rows ClickSend shows now for that recipient and exact `custom_string`, possibly none. It
  widens the date window by five minutes on each side, reads every page (100 rows each), and
  requires an E.164 recipient. An empty result is not proof that nothing was sent.
- Testing: `FakeAPI` cancels messages it holds as scheduled for the future
  (`fake.cancelled_messages`) and raises `StubError` for every cancel ClickSend doesn't document,
  so tests must stub that answer. `fake.stub_history(*messages, status: "Sent")` states what
  history shows; the fake still serves no history by itself.

### Fixed

- **Instrumenters that don't run the block synchronously can no longer send late or return nil.**
  A `request.clicksend` block kept by the instrumenter and called after `#instrument` returned
  now raises `ConfigurationError` without sending (before, the call raised `ConfigurationError`
  and the SMS was sent later anyway). If `#instrument` returns while the block is still running on
  another thread, or after swallowing an exception that escaped the request, the call raises a
  `ConfigurationError` that is also an `AmbiguousRequestError` unless the request is idempotent
  (before, `Client#request` could return nil while the send went ahead).
- **`Clicksend::Client` refuses `Marshal.dump`** (`TypeError`), including inside another object
  such as `client.sms`. A client holds the API key, which `Marshal` used to write out in clear
  (e.g. into a cache or a job payload). Build a new client instead. Responses and errors can still
  be marshaled.

### Changed

- **Webhook documentation corrected from new evidence** (`Clicksend::Webhook` is still
  experimental; no behaviour changed). Archived ClickSend help articles and ClickSend's own n8n
  and Power Automate integrations list the pushed fields, including legacy duplicates (`message`,
  `sms`, `originalsenderid`, `messageid`, `customstring`, ...) that stay in `#raw`. The README and
  API notes no longer say that no source ever listed IP addresses: an archived article did, but it
  is stale and unpublished, so the gem still offers no allowlist. Archived sources disagree on the
  retry schedule, which is now said. Receipts must be deduplicated on `message_id` and
  `status_code`, not `message_id` alone, because a message may get more than one receipt. New
  receiver advice: secret rotation, `discard_on Clicksend::Webhook::InvalidPayload`, Rails'
  log filtering, voice/email/fax receipts sharing the format, inbound MMS links, and the
  dashboard's "Add Test Reply".

### Development

- Webhook replay fixtures (`spec/fixtures/webhooks`, one per published push shape, replayed
  through Rack's request parsing) and `script/webhook_capture.rb`, which captures real pushes
  locally and redacts them into fixtures. `rack` is a new development dependency.

## [1.1.0] - 2026-10-06

Failure semantics, observability and testing support for production messaging. Mostly additive;
read "Changed" before upgrading. Two additions are **experimental** and may change in a minor
release: `Clicksend::Webhook` and `Clicksend::RateLimit`, because both rest on behaviour ClickSend
doesn't document.

Retry safety is unchanged in principle and stricter in practice. ClickSend has no idempotency key,
so a send that may already have been processed is never repeated automatically, and such failures
are now marked as ambiguous. This reduces the risk of duplicate SMS; it is not a guarantee against
every possible duplicate (for example, a job runner re-running a job after a crash).

### Added

- **Explicit ambiguity.** When a request that is not safe to repeat (such as an SMS send) fails
  in a way that ClickSend may still have processed, the error is extended with
  `Clicksend::AmbiguousRequestError`. That covers:
  - a timeout or reset after the request may have been written;
  - a 5xx;
  - an error reported inside a 2xx body;
  - a 2xx answer the gem can't read, including a send result without a per-message status.

  The error keeps its class, so existing `rescue` clauses still work. `Error#ambiguous?` is the
  predicate. (A `dup` of the error loses the mark; `clone` and re-raising keep it.)
- **Request context on errors and responses.** `Error#request` and `Response#request` return a
  `Clicksend::RequestInfo` with `http_method`, `path` (no query string or fragment), `operation`
  (e.g. `"sms.deliver"`), `idempotent` and `attempts`. `Response#request` is not a `Data`
  member, so `Response` equality, `to_h` and pattern matching are unchanged from 1.0.
- `Error#retryable?`: whether repeating the same request later is both safe and might succeed.
- **Retry configuration.** `Clicksend::RetryPolicy` is public:
  `Client.new(retry_policy: RetryPolicy.new(max_retries:, base_delay:, max_delay:, max_retry_after:))`.
  The rule deciding *which* failures may be retried lives in the connection and cannot be
  changed by any policy, and the connection enforces the policy's own `max_retries`.
- **Rate limits (experimental).** `Response#rate_limit` and `APIError#rate_limit` return a
  `Clicksend::RateLimit` (`limit`, `remaining`, `reset_in`) from the rate-limit headers observed
  live on `GET /v3/account`. They are nil when ClickSend sends none.
- **Instrumentation.** `Client.new(instrumenter:)` accepts `ActiveSupport::Notifications` or any
  object with the same `instrument` signature that yields once. It publishes `request.clicksend`
  and `retry.clicksend`. Payloads never include credentials, query strings or bodies, and the
  wrapped methods' paths contain no phone numbers or message text. `Client#request` and
  `#paginate` take an optional `operation:` label.
- **Message history.** `sms.history(date_from:, date_to:, to:/from:/status:/message_id:, order:)`
  returns a page of `Clicksend::SMS::HistoryRecord`, whose `delivered?`, `failed?` and `pending?`
  follow ClickSend's "SMS error codes" article and are all false when a row can't be classified
  (e.g. "Completed" with no gateway code, as observed live). ClickSend documents no way to look up
  a send by your own reference; history, filtered by recipient and matched on `custom_string`, is
  the closest. The README explains why a missing row is not proof that nothing was sent.
- **Webhooks (experimental).** `Clicksend::Webhook.parse_receipt`, `.parse_inbound` and `.parse`
  turn pushed receipts and replies into `SMS::Receipt` and `SMS::InboundMessage`. ClickSend
  documents no way to authenticate pushes, so there is deliberately no verification method; the
  README explains how to secure the endpoint. No real push has been captured yet.
- **Testing.** `require "clicksend/testing"` adds `Clicksend::Testing::FakeAPI`, an in-memory
  ClickSend you plug in as the transport, covering sends, receipts, replies and the account. It
  records sent messages and can inject failures, including ambiguous ones with an explicit
  `processed:` flag. It deliberately doesn't serve history; stub it. Mistakes in stubs surface
  as `Clicksend::Testing::StubError` (not a `StandardError`), never as a simulated ClickSend
  failure.

### Changed

Behaviour an existing 1.0 application may notice:

- **Mark-read without a cutoff is no longer retried.** `sms.mark_receipts_read` and
  `sms.mark_inbound_read` with no `before:` mark *everything* read at the moment ClickSend
  processes the call. Retrying after an unknown outcome could hide items that arrived in between.
  With `before:` they are still retried.
- **Error messages end with the request they came from**, e.g. `HTTP 500 (POST /v3/sms/send)`.
  Code that matched the exact message text needs updating. `MessageRejected` now carries
  `#request` too.
- **Unreadable 2xx answers to sends are ambiguous.** Before, they were plain
  `MalformedResponseError`s. That covers `deliver` and `deliver_batch`, including a message
  without a status, which 1.0 reported as a rejection (`MessageRejected` with a nil status, or
  in `Batch#rejected`).
- **Custom transports:**
  - An exception that is not a `Clicksend::Error` becomes a `ConnectionError` that may have been
    sent. It is ambiguous for a send, retried for idempotent requests, and keeps the original as
    `#cause`; `rescue MyTransportError` around client calls no longer matches.
  - Any other `Clicksend::Error` raised by a transport is treated as an unknown outcome.
  - A response without a valid HTTP status, or an unexpected 1xx/3xx, is ambiguous for a send
    instead of being a rejection.
  - Exceptions raised by transports are copied before context is added.
- **Loggers and instrumenters cannot change a result.** A logger or instrumenter that raises
  after a request completes is logged and ignored. An instrumenter that never runs the block
  raises `ConfigurationError`, and one that runs it twice can't send twice.
- **Configuration:**
  - `Client.new(max_retries:)` and `retry_policy:` are mutually exclusive. `Client#with` replaces
    one with the other, and `max_retries: nil` now means the default.
  - `RetryPolicy.new` validates its arguments (`ConfigurationError`) and returns a frozen policy.
  - `Client#request(idempotent:)` honours only `true`; other truthy values, such as `1` or
    `"false"`, no longer make a request retryable.

### Compatibility

- Ruby 3.3 or newer, as before; tested on 3.3, 3.4 and 4.0, with a Ruby head canary in CI.
- Faraday 2 remains the only runtime dependency. ActiveSupport is used only in this gem's own
  tests; `instrumenter:` duck-types it.
- No public method or class from 1.0 was removed. `require "clicksend/testing"` is opt-in and
  not loaded by `require "clicksend"`.

### Verification

- Unit, integration (local real-socket servers) and contract specs cover the new behaviour.
  Contract specs check the wrapped operations, the fields the models read, and the documented
  page-size range against ClickSend's published OpenAPI files.
- Live checks on 2026-10-06 were read-only: `sms.history` filtered to ClickSend's test number,
  and the rate-limit headers on `GET /v3/account`. No SMS was sent.
- **Not verified live:** a webhook push (none has been captured), and a delivery receipt. The
  test number produced none, as ClickSend's legacy docs say it won't. Both are parsed according
  to ClickSend's published schemas and archived documentation.

### Documentation

- README: positioning, unknown send outcomes and reconciliation, webhooks, history, background
  jobs (including at-least-once job runners), instrumentation, and rate limits. Behaviour that
  ClickSend doesn't document is labelled as inferred or observed.
- API notes: a review of all 34 of ClickSend's OpenAPI sections plus the archived push
  documentation; read-only live checks of history and rate-limit headers on 2026-10-06.
- `design/1.1-audit-and-roadmap.md`: the audit, the decisions taken, the features rejected, and
  the reviews.

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

[Unreleased]: https://github.com/prayantr/clicksend/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/prayantr/clicksend/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/prayantr/clicksend/compare/v1.0.0.rc1...v1.0.0
[1.0.0.rc1]: https://github.com/prayantr/clicksend/compare/c99edc5...v1.0.0.rc1
[0.0.3]: https://github.com/prayantr/clicksend/tree/c99edc5
