# Handoff: project state and settled decisions

For maintainers and for anyone (or any AI session) starting the next phase. Last reconciled
against the repository, GitHub and RubyGems on 2026-10-09. Release mechanics are in
[`CONTRIBUTING.md`](CONTRIBUTING.md); API evidence is in
[`docs/clicksend-api-notes.md`](docs/clicksend-api-notes.md); user-facing behaviour is in
[`README.md`](README.md) and [`CHANGELOG.md`](CHANGELOG.md).

> **When the next phase begins, start from master at the frozen 1.2.0 baseline. Do not resurrect
> old branches or research worktrees unless the task explicitly calls for their historical context.**

## Frozen baseline

| | |
|---|---|
| `master` | The only branch. Its code (`lib/`, both gemspecs) is exactly the released code: nothing under `lib/` has changed since `v1.2.0`. Later commits are CI, documentation and this file |
| `clicksend` | **1.2.0**, stable and the default version on RubyGems (published 2026-10-06) |
| `clicksend-opentelemetry` | **0.1.0** (published 2026-10-06), from `companions/clicksend-opentelemetry` |
| Release tags (annotated) | `v1.0.0.rc1` → `595c466`, `v1.0.0` → `d460f9e`, `v1.1.0` → `dc792c4`, `v1.2.0` → `9ce4956`, `clicksend-opentelemetry-v0.1.0` → `b8c6bc6`; the 2014 release `0.0.3` → `c99edc5` |
| Archive tags | `archive/research-ecosystem`, `archive/spike-1.2-observability-http`: research code only, see [`research/README.md`](research/README.md) |
| GitHub releases | clicksend 1.0.0, 1.1.0 and 1.2.0 (latest); clicksend-opentelemetry 0.1.0 (deliberately not "latest"). No release for 1.0.0.rc1 |
| Ruby | `>= 3.3`. Supported and tested: 3.3, 3.4, 4.0. Ruby head runs in CI as a canary that is allowed to fail; it is not a supported target |
| Runtime dependencies | Core: Faraday `>= 2.0.1, < 3`, nothing else. Companion: `clicksend ~> 1.1`, `opentelemetry-api ~> 1.1` (never a dependency of the core) |
| Tests at 1.2.0 | 675 examples (0 failures); 50 contract examples against ClickSend's published OpenAPI files; `lib/` coverage 99.58% line, 97.84% branch (reported, not enforced). Companion: 23 examples against this checkout, and the same suite against clicksend 1.1.0 from RubyGems with one 1.2-only example skipped |

Published `.gem` SHA-256 (each matches a byte-identical rebuild of its tag):

| Gem | SHA-256 |
|---|---|
| clicksend 1.0.0 | `a36976941399c88a91c14a1c84547595b65a50fbed635e0cb0e0f9ee10ce5c4e` |
| clicksend 1.1.0 | `12948d70ff172c439f0c15e60d09af44f89edd28c2718c2d4925b7d378472a18` |
| clicksend 1.2.0 | `f8fa8f43a30b7a4b8e592eca20ea331e3758a6640b3e84f29ef160773c678652` |
| clicksend-opentelemetry 0.1.0 | `6593452d5f0eba037fe83d97d020044a027f47cf41185bf8da251e28d8a135de` |

## Positioning and architecture

- **Why it exists.** ClickSend has an official, generated Ruby SDK (`clicksend_client`) that covers
  most of the API. This gem is deliberately not a second SDK: it is a focused SMS client that does a
  few things carefully (sending, receipts, replies, history, balance) and complements the official
  one. The README says when to use the official SDK instead.
- **Namespace.** `Clicksend`, because the official SDK owns `ClickSend`; both load side by side.
- **Core API.** A frozen, thread-shareable `Clicksend::Client` with explicit configuration (arguments
  or `CLICKSEND_USERNAME` / `CLICKSEND_API_KEY`); no global state. Resources: `client.sms`,
  `client.account`. Models keep ClickSend's full payload in `#raw`.
- **Escape hatch.** `client.request` and `client.paginate` reach any endpoint through the same
  authentication, timeouts, retry rule, typed errors and parsing; paths are validated so credentials
  can never be sent to another host.
- **Retry and ambiguity.** "A missed retry is recoverable; a duplicate SMS is not." The connection
  decides *which* failures may be retried (not sent at all, 429, or idempotent requests); a
  `RetryPolicy` only sets timing and budget. A failure ClickSend may still have processed is marked
  `AmbiguousRequestError` and is never retried for a non-idempotent request. Errors and responses
  carry `RequestInfo` (method, path without query, operation, idempotent, attempts).
- **Pagination.** `Page`, lazy `auto_paging_each`, ClickSend's documented 15 to 100 page size.
- **Typed errors.** Every failure of a request (configuration, connection, API, response) is a
  `Clicksend::Error`: `ConfigurationError`, `ConnectionError`/`TimeoutError`, `APIError` subclasses by
  status, `MalformedResponseError`, `MessageRejected`. Invalid arguments raise `ArgumentError` before
  any request; the test fake's `StubError` is deliberately not a `Clicksend::Error`. Loggers, instrumenters, policies and custom transports cannot change a result,
  including when they raise `ScriptError`.
- **Security model.** HTTPS-only `base_url` (HTTP for localhost); no credentials in `inspect`, logs or
  errors; logs omit bodies and query strings; the echoed subaccount API key is redacted in
  `Account#raw`; a client refuses `Marshal` and `YAML`; message IDs are validated before entering
  paths. Private vulnerability reporting via `SECURITY.md`.
- **Observability.** `instrumenter:` compatible with `ActiveSupport::Notifications`
  (`request.clicksend`, `retry.clicksend`); `logger:`; experimental `Clicksend::RateLimit`.
- **Testing.** `require "clicksend/testing"`: `FakeAPI` (an in-memory transport), `fail_next`
  (including `:interrupted`), `stub_history`, `cancelled_messages`; opt-in `clicksend/testing/rspec`
  and `clicksend/testing/minitest`. The fake refuses to guess undocumented API answers.
- **OpenTelemetry.** `clicksend-opentelemetry`, built only on the public instrumenter hook: one CLIENT
  span per call, retries as events, ambiguity as an attribute, never phone numbers, bodies, query
  strings or credentials.

## What 1.2.0 added

- `sms.search_history(to:, custom_string:, sent_after:, sent_before:)`: exact matches only; an empty
  result never means "not sent".
- `sms.cancel(message_id)`, **experimental**: never retried after an ambiguous failure.
- Testing helpers: interrupted-send simulation, RSpec matchers, Minitest assertions, `stub_history`.
- Persistent connections, opt-in (`adapter: :net_http_persistent`), with failures before the write
  classified as not sent.
- Webhook replay fixtures (`spec/fixtures/webhooks/`) and `script/webhook_capture.rb`.
- Background-job and observability guidance in the README (measured locally against stand-ins).
- Hardening: instrumenter lifecycle guard, `ScriptError` handled as a foreign failure, Marshal/YAML
  refused, strict `Retry-After`, unsleepable delays mean "don't retry".
- The `clicksend-opentelemetry` 0.1.0 companion.

## Settled decisions (non-goals)

Reopen any of these only with new evidence, not by default:

- Do not become a second full SDK.
- Never retry an ambiguous SMS send automatically, and never resend because history shows nothing
  ("not yet" and "never" look the same).
- No `cancel-all` wrapper: without a filter it cancels every scheduled message on the account.
- No webhook signature or HMAC verification: ClickSend documents none to verify. No IP allowlist
  helper, no deduplicator with storage in the gem.
- No global configuration (`Clicksend.configure`), no ActionMailer-style layer, no monkey-patching.
- No Rails engine in the core. No `clicksend-rails` or `clicksend-sidekiq` companion unless real
  users ask for it; README recipes cover the job patterns.
- Persistent connections stay opt-in, never the default.
- No paid live tests, and no live ClickSend call without the owner's explicit approval. Live specs
  use only ClickSend's free test number.

## Known limitations

- **A successful `sms.cancel` has never been observed live.** Its 200 answer is covered by contract
  specs only. Free test-number messages show as `Completed` within seconds, so cancelling them answers
  404 `NOT_FOUND` (raised as `NotFoundError`); a repeat or an unknown ID gets the same 404, so a 404
  never means "already sent". Proving success needs a paid scheduled message, which is not authorised.
- No paid SMS has ever been sent; no live delivery receipt and no live webhook push have been observed.
  Webhook parsing and `RateLimit` stay experimental.
- Background-job measurements used local stand-ins, not ClickSend.
- Ruby head is a canary, not a supported target.
- Deferred: a deterministic cross-thread spec for the instrumenter lock (two mutations survive);
  `ActiveSupport`'s `as_json` can still serialise a client (documented: pass job arguments, not
  clients).

## Release and security state

- **`master` ruleset:** pull request required (no approvals needed), branch up to date, no force
  push, no deletion, no bypass. Required checks (12): `Ruby 3.3`, `Ruby 3.4`, `Ruby 4.0`, `lint`,
  `audit`, `build`, and `clicksend-opentelemetry / current core (this checkout)` and
  `clicksend-opentelemetry / oldest supported core (clicksend 1.1.0)`, each on Ruby 3.3, 3.4 and 4.0.
  `Ruby head` and `contract` run on every pull request but are deliberately not required.
- **Release-tag ruleset:** `v*`, `clicksend-opentelemetry-v*` and `0.0.3` can be created but never
  moved or deleted, by anyone. A tag on the wrong commit means a new version.
- **Trusted Publishing:** `release.yml` (environment `rubygems`, `v*` tags only) and
  `release-clicksend-opentelemetry.yml` (environment `rubygems-clicksend-opentelemetry`,
  `clicksend-opentelemetry-v*` tags only); both manual, `contents: read` and `id-token: write`, actions
  pinned to commit SHAs. No RubyGems API key exists anywhere.
- **Supply chain:** the default workflow token is read-only and Actions cannot approve pull requests;
  `live.yml` is pinned too, since it can hold credentials. Secret scanning and push protection are on.
  `bundle-audit` checks all three lockfiles (`Gemfile.lock`, the companion's `Gemfile.lock` and
  `gemfiles/clicksend-1.1.gemfile.lock`). Dependabot: weekly Bundler and GitHub Actions updates
  (it also bumps the SHA pins), vulnerability alerts and security updates.
- **Compatibility CI:** the companion's suite runs against clicksend 1.1.0 from RubyGems, keeping its
  `~> 1.1` claim honest.
- **Contract CI:** weekly and on pull requests, against ClickSend's published OpenAPI files.

## Candidates for a future phase (not a roadmap)

Each needs fresh evidence before any work starts:

- Webhooks out of "experimental", plus a `params_from(rack_request)` helper: needs real captured
  pushes (`script/webhook_capture.rb`, `research/1.2-webhooks.md`).
- `sms.quote` (`POST /v3/sms/price`): needs proof the endpoint has no side effects.
- `sms.cancel` out of "experimental": needs one owner-approved, paid scheduled send that is then
  cancelled.
- `sms.cancel_matching(custom_string:)` with a required filter: only after a live check shows exact,
  case-sensitive matching.
- `clicksend-rails` (ActiveJob concern, Rails defaults): only if users ask.
- Live checks the research left open (owner approval needed): receipts on an account with only URL
  rules; ClickSend's keep-alive idle timeout.
