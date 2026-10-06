# clicksend

[![CI](https://github.com/prayantr/clicksend/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/prayantr/clicksend/actions/workflows/ci.yml)
[![Gem Version](https://img.shields.io/gem/v/clicksend)](https://rubygems.org/gems/clicksend)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE.txt)

A focused, idiomatic Ruby client for production messaging workloads on ClickSend's REST v3 API:
single and batch SMS, delivery receipts and replies (polled or pushed), message history and
account balance.

It is **not** another complete ClickSend SDK. ClickSend's official SDK wins on breadth. This gem
concentrates on the messaging core and on what running it in production needs:
- Timeouts are on by default, and errors are typed and say which request failed.
- A message ClickSend refuses inside an HTTP 200 response is reported as an error, not
  silently treated as sent.
- Retries are designed to avoid sending a duplicate SMS. A missed retry is recoverable; a
  duplicate SMS is not. When a send's outcome is unknown, the error says so
  ([`AmbiguousRequestError`](#when-a-sends-outcome-is-unknown)), and history lets you check.
- Instrumentation for ActiveSupport::Notifications, an in-memory fake ClickSend for your
  tests, and parsers for ClickSend's webhooks.

Endpoints it doesn't wrap are one [`client.request`](#calling-other-clicksend-endpoints) away,
through the same safe request path ([which client should I use?](#which-client-should-i-use)).

```ruby
require "clicksend"

client = Clicksend::Client.new(username: ENV["CLICKSEND_USERNAME"], api_key: ENV["CLICKSEND_API_KEY"])

message = client.sms.deliver(to: "+61411111111", body: "Your code is 481516")
message.message_id # => "1ABC3200-C38C-6308-BE4B-C7C51D01DCF0"
```

> **Stable (1.x)**. Unofficial: not affiliated with ClickSend.
>
> Upgrading from the 2014 `0.0.x` gem? Read [MIGRATING.md](MIGRATING.md). The namespace changed
> from `ClickSend` to **`Clicksend`**.

## Contents

- [Which client should I use?](#which-client-should-i-use)
- [Installation](#installation)
- [Configuration](#configuration)
- [Sending SMS](#sending-sms)
- [When a send's outcome is unknown](#when-a-sends-outcome-is-unknown)
- [Delivery receipts and replies](#delivery-receipts-and-replies)
- [Webhooks](#webhooks)
- [Message history](#message-history)
- [Account balance](#account-balance)
- [Pagination](#pagination)
- [Errors](#errors)
- [Timeouts, retries and rate limits](#timeouts-retries-and-rate-limits)
- [Background jobs](#background-jobs)
- [Calling other ClickSend endpoints](#calling-other-clicksend-endpoints)
- [Logging, instrumentation and thread safety](#logging-instrumentation-and-thread-safety)
- [Testing your application](#testing-your-application)
- [What is covered](#what-is-covered)
- [Using it alongside the official SDK](#using-it-alongside-the-official-sdk)
- [Background and design](#background-and-design)
- [Development](#development)

## Which client should I use?

| You want to… | Use |
|---|---|
| Send SMS from a Ruby app and track delivery and replies, with safe defaults, typed errors, instrumentation and a test fake | **this gem** |
| Call the occasional ClickSend endpoint this gem doesn't wrap (price a message, cancel a scheduled one, list templates) with the same authentication, timeouts, retry rules and errors | **this gem's [`client.request`](#calling-other-clicksend-endpoints)** |
| Work with large parts of the API (email, campaigns, contacts, numbers, automations, subaccounts, and so on) with generated models for each | ClickSend's official SDK, [`clicksend_client`](https://rubygems.org/gems/clicksend_client) |

The two gems can be used side by side ([namespaces differ](#using-it-alongside-the-official-sdk)).

Comparison with ClickSend's official SDK (`clicksend_client` 6.0.2, September 2026). This is
a snapshot; the official SDK may have changed since.

| | `clicksend` (this gem) | `clicksend_client` 6.0.2 |
|---|---|---|
| Scope | SMS, receipts, replies, balance; `client.request` for anything else | Most of the API, generated from OpenAPI |
| Timeouts | On by default (30s read, 5s connect) | Off by default (`timeout = 0`) |
| Retries | Built in; designed not to re-send a message that may already have reached ClickSend | None |
| A message refused inside an HTTP 200 | `deliver` raises `MessageRejected`; `deliver_batch` exposes `#rejected` | Left for you to check |
| Errors | Typed by status, with the failed request, `retryable?` and `ambiguous?` | One `ApiError` with status, headers and body |
| Pagination | `auto_paging_each` | Manual `page`/`limit` |
| Webhooks | `Clicksend::Webhook` parses receipts and replies | Not covered |
| Testing | `Clicksend::Testing::FakeAPI`, an in-memory ClickSend | Not covered |
| Instrumentation | ActiveSupport::Notifications events, without personal data | Not covered (debug mode prints credentials and bodies) |
| Configuration | Immutable client instances | Global `Configuration.default` (per-instance possible) |
| Runtime dependencies | Faraday 2 | Typhoeus (libcurl) |

## Installation

Requires Ruby 3.3 or newer. Tested on Ruby 3.3, 3.4 and 4.0; support for a Ruby ends in a minor
release after its end of life.

```sh
gem install clicksend
```

```ruby
# Gemfile
gem "clicksend", "~> 1.0"
```

The only runtime dependency is [Faraday](https://github.com/lostisland/faraday) 2.x.

## Configuration

Create a client with your ClickSend API username and API key. You can find them in the
dashboard under *Developers → API Credentials*:

```ruby
client = Clicksend::Client.new(
  username: ENV["CLICKSEND_USERNAME"],
  api_key: ENV["CLICKSEND_API_KEY"]
)
```

With no arguments, `Clicksend::Client.new` reads `CLICKSEND_USERNAME` and `CLICKSEND_API_KEY`.
A missing credential raises `Clicksend::ConfigurationError` straight away, not on the first request.

| Option | Default | |
|---|---|---|
| `username`, `api_key` | `ENV["CLICKSEND_USERNAME"]`, `ENV["CLICKSEND_API_KEY"]` | HTTP Basic credentials |
| `timeout` | `30` | Seconds to wait for a response |
| `open_timeout` | `5` | Seconds to wait for the connection |
| `max_retries` | `2` | Retries for failures that are safe to retry; `0` disables them |
| `retry_policy` | `RetryPolicy.new` | Backoff timing and retry budget ([details](#timeouts-retries-and-rate-limits)); instead of `max_retries` |
| `logger` | `nil` | Any object with `#info`/`#warn`, e.g. `Rails.logger` |
| `instrumenter` | none | e.g. `ActiveSupport::Notifications` ([events](#logging-instrumentation-and-thread-safety)) |
| `base_url` | `https://rest.clicksend.com` | HTTPS only (HTTP is allowed for `localhost`) |
| `adapter` | Net::HTTP | Faraday adapter, e.g. `[:net_http_persistent, {pool_size: 5}]` |
| `transport` | Faraday | Replaces the HTTP layer entirely (see [Testing](#testing-your-application)) |

Clients are immutable. `with` returns a copy with some settings changed. That is useful for
[subaccount](https://developers.clicksend.com/docs/accounts/subaccounts) credentials or a
latency-sensitive code path:

```ruby
subaccount = client.with(username: "acme-sub", api_key: ENV["ACME_SUB_KEY"])
fast = client.with(timeout: 5, max_retries: 0)
```

In Rails, build one client in an initializer and reuse it:

```ruby
# config/initializers/clicksend.rb
CLICKSEND = Clicksend::Client.new(logger: Rails.logger)
```

## Sending SMS

### One message

```ruby
message = client.sms.deliver(
  to: "+61411111111",              # E.164
  body: "Your code is 481516",     # ClickSend detects Unicode and splits long messages
  from: "Acme",                    # optional: alpha tag, dedicated number or verified own number
  schedule: Time.now + 3600,       # optional: Time or Unix timestamp
  custom_string: "otp:user-42"     # optional: echoed back in receipts and replies
)

message.queued?   # => true
message.status    # => "SUCCESS"
message.parts     # => 1
message.price     # => "0.0792" (a decimal String; use BigDecimal(message.price) for arithmetic)
```

ClickSend answers `POST /v3/sms/send` with HTTP 200 even when it refuses the message.
In that case the reason is given in a per-message `status`. `deliver` turns that into an exception:

```ruby
begin
  client.sms.deliver(to: "+610", body: "hi")
rescue Clicksend::MessageRejected => e
  e.status   # => "INVALID_RECIPIENT"
  e.result   # => #<Clicksend::SMS::Message ...>
end
```

Other optional arguments are `country:`, `source:`, `from_email:` and `shorten_urls:`.
Unknown keywords raise `ArgumentError`, so typos can't be silently ignored.

> ClickSend currently pauses SMS containing URLs for new customers until URL messaging is
> approved ([docs](https://developers.clicksend.com/docs/messaging/sms)).

### Many messages in one request

```ruby
batch = client.sms.deliver_batch(
  [
    {to: "+61411111111", body: "Hi Ann"},
    {to: "+61422222222", body: "Hi Bob", custom_string: "bob"},
    {list_id: "428", body: "Hi everyone on list 428"}
  ],
  from: "Acme"                     # defaults for every message; a message's own value wins
)

batch.all_queued?  # => false if any message was rejected or blocked
batch.queued       # => [#<Clicksend::SMS::Message ...>, ...]
batch.rejected.each { |m| warn "#{m.to}: #{m.status}" }
batch.total_price  # => "0.2376"
```

`deliver_batch` never raises when only some messages fail; check `#rejected`.
Each message needs `body` and exactly one of `to` or `list_id`. ClickSend doesn't document that
results come back in request order, so match them to your own records by `custom_string`
(or `to`), not by position.

## When a send's outcome is unknown

ClickSend's send endpoint accepts no idempotency key. If the connection drops or times out after
the request was written, or ClickSend answers with a 5xx, the message may or may not have been
accepted. The gem never retries such a send. It raises the error extended with
`Clicksend::AmbiguousRequestError`:

```ruby
begin
  client.sms.deliver(to: user.phone, body: text, custom_string: "otp:#{attempt.id}")
rescue Clicksend::AmbiguousRequestError => e
  e.class          # => Clicksend::TimeoutError (or ServerError, ConnectionError, MalformedResponseError)
  e.request        # => #<Clicksend::RequestInfo POST /v3/sms/send operation="sms.deliver" idempotent=false attempts=1>
  e.retryable?     # => false
  # Decide before sending again: check history (below), or let the user ask for a new code.
end
```

It is still the error class it was, so `rescue Clicksend::TimeoutError` keeps working.
Failures that are known not to have been processed (a refused connection, a 429, a 4xx, or a
message ClickSend refused) are not ambiguous.

To check, look the message up in [history](#message-history) by recipient and match your own
`custom_string`:

```ruby
sent = client.sms.history(to: user.phone, date_from: started_at - 60)
  .auto_paging_each.find { |record| record.custom_string == "otp:#{attempt.id}" }
```

ClickSend doesn't document how soon a sent message appears in history, so **a message missing
from history is not proof that it wasn't sent**. Whether to resend is your decision: for a login
code, letting the user request another is usually safer than resending automatically.

## Delivery receipts and replies

ClickSend can push receipts and replies to a [webhook](#webhooks), or you can poll for them.
Polling needs rules with the **POLL** action for SMS receipts and inbound SMS. You can set these
up in the dashboard or through the
[automations API](https://developers.clicksend.com/docs/automations/sms). ClickSend's test
numbers never produce receipts.

```ruby
started_at = Time.now
client.sms.receipts.auto_paging_each do |receipt|
  receipt.message_id     # matches Message#message_id
  receipt.custom_string
  receipt.delivered?     # status_code 201
  receipt.failed?        # status_code 301 (see receipt.status_text / error_code)
  receipt.pending?       # status_code 200 or 300 (not final yet)
end
client.sms.mark_receipts_read(before: started_at)

client.sms.inbound.auto_paging_each do |reply|
  reply.from
  reply.body
  reply.original_message_id  # the message this replies to
end
client.sms.mark_inbound_read(before: started_at)     # or every unread reply, with no argument
client.sms.mark_inbound_message_read(reply.message_id) # just one
```

Status codes follow ClickSend's
[SMS error codes](https://help.clicksend.com/en/articles/42318-sms-error-codes) article.
`client.sms.receipt(message_id)` fetches a single receipt, including receipts already marked read.

> These lists contain only **unread** items, and listing doesn't mark anything read. If you mark
> items read while paging through them, later pages shift and you will skip some. Process the
> pages first, then call `mark_*_read(before:)` with the time you started. Without `before:`,
> ClickSend marks *everything* read, including items that arrived after you listed them, so that
> form is never retried. There is no way to mark a single receipt read.

## Webhooks

ClickSend pushes receipts and replies to your URL through automation rules with the **URL**
action. `Clicksend::Webhook` turns a push into the same models polling returns:

```ruby
# config/routes.rb: post "clicksend/:secret/receipts", to: "clicksend_webhooks#receipt"
class ClicksendWebhooksController < ActionController::API
  def receipt
    secret = Rails.application.credentials.clicksend_webhook_secret
    return head(:not_found) unless ActiveSupport::SecurityUtils.secure_compare(params[:secret].to_s, secret)

    receipt = Clicksend::Webhook.parse_receipt(request.request_parameters) # => Clicksend::SMS::Receipt
    TrackDeliveryJob.perform_later(receipt.message_id)                      # idempotent on message_id
    head :ok
  rescue Clicksend::Webhook::InvalidPayload
    head :bad_request
  end
end
```

`Webhook.parse_inbound(params)` returns a `Clicksend::SMS::InboundMessage`, and `Webhook.parse`
works out which of the two it was given. Pass the body parameters, not the route ones, so your
secret isn't kept in `#raw`.

**ClickSend doesn't sign or authenticate webhooks.** It documents no signature, shared secret or
IP ranges, so anyone who learns the URL can send a fake receipt. This gem therefore offers no
"verify" method. Instead:
- put an unguessable secret in the URL, compare it in constant time, and use HTTPS;
- treat a push as a hint, and confirm anything that matters with `client.sms.receipt(message_id)`;
- handle pushes idempotently by `message_id`: several rules can match, and (according to
  ClickSend's archived docs) a non-200 answer is retried every 10 minutes, up to 10 times;
- answer 200 quickly and do the work in a job.

Receipt rules post form fields. Inbound rules post form fields by default, or use a query string
(`webhook_type: "get"`) or JSON (`"json"`). ClickSend's current documentation doesn't define the
push fields. The parsers use the field names of the polling API, which match ClickSend's archived
push documentation, and reject payloads with too many fields, oversized values or nested values.

## Message history

```ruby
client.sms.history(date_from: Time.now - 86_400, to: "+61411111111").auto_paging_each do |record|
  record.direction      # "out" (sent) or "in" (received)
  record.status         # "Sent", "Completed", "Failed", "Scheduled", ... (history statuses)
  record.status_code    # the gateway code receipts use: 201 delivered, 301 failed; may be nil
  record.custom_string
end
```

ClickSend documents one search filter per request, so `history` takes at most one of `to:`,
`from:`, `status:` and `message_id:`, plus `date_from:`, `date_to:` and `order:` (`:asc` or
`:desc`). `custom_string` isn't a documented filter; match it yourself.

## Account balance

```ruby
account = client.account.fetch
account.balance   # => "4.998000"
account.currency  # => "AUD"
account.raw       # every field ClickSend returned (with one exception, below)
```

Every model keeps the full payload in `#raw`, so fields this gem doesn't name are still there.
The one exception is the account response. ClickSend includes the API key there
(`_subaccount.api_key`), and the gem replaces it with `"[REDACTED]"` so an `Account` is safe to log.
The raw body from `client.request(:get, "/v3/account")` still contains the key, so don't log it.

## Pagination

List methods return a `Clicksend::Page`. A page is `Enumerable` over its own items.
`auto_paging_each` walks every page, fetching each one only when it is needed:

```ruby
page = client.sms.receipts(limit: 100)    # limit: 15..100 (ClickSend's documented range)
page.total; page.current_page; page.last_page
page.each { |receipt| ... }               # this page only
page.next_page                            # => the following Page, or nil

client.sms.receipts.auto_paging_each.first(250)  # stops fetching after 250 items
```

## Errors

Every error is a `Clicksend::Error`:

```
Clicksend::Error              #request #retryable? #ambiguous?
├── ConfigurationError        missing credentials, invalid options
├── ConnectionError           no response: DNS, refused, TLS, reset   #request_may_have_been_sent?
│   └── TimeoutError
├── APIError                  #http_status #response_code #response_msg #headers #body #rate_limit
│   ├── ClientError           other 4xx
│   │   ├── BadRequestError       400
│   │   ├── AuthenticationError   401
│   │   ├── ForbiddenError        403
│   │   ├── NotFoundError         404
│   │   └── RateLimitError        429   #retry_after
│   └── ServerError           5xx
├── MalformedResponseError    not JSON, or missing documented fields
├── MessageRejected           deliver: the message was refused   #status #result
└── Webhook::InvalidPayload   a push that can't be parsed

Clicksend::AmbiguousRequestError (module)   extended onto any of the above when the outcome is unknown
```

- `#request` is a `Clicksend::RequestInfo`: `method`, `path` (never the query string),
  `operation` (e.g. `"sms.deliver"`), `idempotent` and `attempts`. The error message ends with
  it: `HTTP 500 (POST /v3/sms/send)`.
- `#retryable?` is true when repeating the same request later is safe *and* might work: a 429, a
  connection that never reached ClickSend, or a timeout or 5xx on a request that is safe to
  repeat. It is false for every ambiguous error, every other 4xx, and `MessageRejected`. (A
  `THROTTLED` rejection means an identical message just went to the same recipient.)
- `#ambiguous?` is true when a request that is not safe to repeat may have been processed. See
  [When a send's outcome is unknown](#when-a-sends-outcome-is-unknown).

`response_code` is ClickSend's application code, for example `INVALID_RECIPIENT`,
`INSUFFICIENT_CREDIT` or `COUNTRY_NOT_ENABLED`; see the
[list](https://developers.clicksend.com/docs/#application-status-codes). Errors keep the
original exception as `#cause`, and their messages never include your credentials, query
strings or bodies.

## Timeouts, retries and rate limits

Timeouts are always on (`timeout: 30`, `open_timeout: 5`). Failed requests are retried
up to `max_retries` times, with exponential backoff and jitter, **only when retrying cannot
send something twice**:

| Failure | Retried for |
|---|---|
| 429 Too Many Requests (waits for `Retry-After` if it is 30s or less) | every request: ClickSend did not process it |
| Connection refused, DNS failure, connect timeout | every request: it never reached ClickSend |
| Read timeout, connection reset, TLS error, 5xx | idempotent requests only: `GET`s, mark-read calls with `before:`, and marking one reply read |
| An error reported inside a 2xx body; any other 4xx | never |

A 429 is documented by ClickSend as a request that "cannot be served", so it is treated as not
processed. That is an inference from the documentation, not a guarantee. When the gem can't tell
whether a failure happened before or after the request was sent, it assumes after. A missed
retry is recoverable; a duplicate SMS is not.

The rules above are fixed. What you can tune is the timing and the budget:

```ruby
client = Clicksend::Client.new(
  retry_policy: Clicksend::RetryPolicy.new(
    max_retries: 3,        # default 2
    base_delay: 0.5,       # seconds; the first backoff is 0.25-0.5s, doubling each time
    max_delay: 8.0,        # cap on the backoff
    max_retry_after: 10    # wait for a Retry-After of at most 10s (default 30); longer raises RateLimitError
  )
)
```

Any object with `max_retries` and `delay(error:, attempt:)` can be a policy. It is only asked
about failures that are safe to retry, so no policy can make a send repeat.

**Rate limits.** ClickSend doesn't publish its rate limits. In testing, `GET /v3/account` allowed
20 requests per roughly 60 seconds, sent `x-ratelimit-limit`, `x-ratelimit-remaining` and
`ratelimit-reset` headers, and answered 429 with `Retry-After` values of 20-39 seconds. Those
headers are undocumented, but when they are present you can read them:

```ruby
response = client.request(:get, "/v3/account")
response.rate_limit  # => #<data Clicksend::RateLimit limit=20, remaining=19, reset_in=60, reset_at=...>, or nil
response.request     # => #<Clicksend::RequestInfo GET /v3/account ... attempts=1>

begin
  client.account.fetch
rescue Clicksend::RateLimitError => e
  e.retry_after      # => 39
  e.rate_limit       # the same fields, from the 429 response
end
```

These retries happen inside the gem. The default Net::HTTP adapter does no retrying of its
own: Faraday sets `max_retries = 0`, and a test pins this. If you pass a different `adapter:`,
check whether that library retries requests by itself.

## Background jobs

Job frameworks retry failed jobs, which can undo the gem's care about duplicates. Retry only
what `retryable?` allows, and never an ambiguous send:

```ruby
class SendSmsJob < ApplicationJob
  # Safe to repeat later: 429s, connections that never reached ClickSend, failed GETs.
  retry_on Clicksend::Error, attempts: 5, wait: :polynomially_longer do |_job, error|
    raise error # attempts exhausted
  end

  def perform(phone, body, reference)
    CLICKSEND.sms.deliver(to: phone, body: body, custom_string: reference)
  rescue Clicksend::Error => e
    raise if e.retryable?                         # let retry_on handle it
    Rails.logger.warn("SMS #{reference} not retried: #{e.message}")
    ReconcileSmsJob.perform_later(reference) if e.ambiguous? # check history before any resend
  end
end
```

`MessageRejected` (for example `INVALID_RECIPIENT`) is not retryable: ClickSend decided.

## Calling other ClickSend endpoints

This gem wraps a small part of ClickSend's API on purpose. Everything else is available through
the same request path: same authentication, timeouts, retry rules, errors and parsing.

```ruby
response = client.request(:post, "/v3/sms/price", body: {messages: [{to: "+61411111111", body: "Hi"}]}, operation: "sms.price")
response.data           # the envelope's "data" (frozen Hash/Array)
response.response_code  # => "SUCCESS"
response.http_status; response.headers; response.body

client.request(:put, "/v3/sms/#{message_id}/cancel")
client.request(:get, "/v3/sms/templates", query: {page: 2})

# Any paginated list, as raw Hashes:
client.paginate("/v3/sms/templates").auto_paging_each { |template| ... }
```

- Write paths exactly as in ClickSend's [API reference](https://developers.clicksend.com/docs/), starting with `/v3/`.
  Full URLs are rejected, so your credentials can't be sent to another host.
- Pass `body:` as a Hash or Array. It is sent as JSON. `query:` values that are `nil` are left out.
- `operation:` is an optional label for logs and [instrumentation](#logging-instrumentation-and-thread-safety).
- Only `GET` requests are treated as idempotent. ClickSend also uses `POST` and `PUT` for actions like sending
  and buying credit. Pass `idempotent: true` only for calls that are safe to repeat. A non-idempotent call
  whose outcome is unknown raises an error extended with `Clicksend::AmbiguousRequestError`, as a send does.

## Logging, instrumentation and thread safety

With `logger:`, every HTTP attempt logs one line, plus a warning for each retry:

```
[clicksend] POST /v3/sms/send -> 200 (184ms)
[clicksend] GET /v3/sms/receipts failed (Clicksend::ServerError), retrying in 0.61s (retry 1 of 2)
```

Lines never contain credentials, query strings, request bodies or response bodies.

With `instrumenter:`, the gem publishes events. Any object with
`instrument(name, payload) { |payload| ... }` works; that is `ActiveSupport::Notifications`'
signature, so in Rails:

```ruby
CLICKSEND = Clicksend::Client.new(logger: Rails.logger, instrumenter: ActiveSupport::Notifications)

ActiveSupport::Notifications.subscribe("request.clicksend") do |event|
  event.payload
  # => {method: :post, path: "/v3/sms/send", operation: "sms.deliver", idempotent: false,
  #     attempts: 1, http_status: 200, response_code: "SUCCESS", ambiguous: false}
  StatsD.distribution("clicksend.request", event.duration, tags: ["operation:#{event.payload[:operation]}"])
end
```

| Event | When | Payload |
|---|---|---|
| `request.clicksend` | around each call, retries included | `method`, `path`, `operation`, `idempotent`; on completion `attempts`, `http_status` (nil without a response), `response_code`, `ambiguous`. ActiveSupport adds `exception` on failure |
| `retry.clicksend` | before each retry | `method`, `path`, `operation`, `attempt`, `delay`, `error_class`, `http_status` |

Payloads never contain credentials, headers, query strings, bodies, phone numbers or message
text. (An exception object attached by ActiveSupport carries the response body of an API error,
as `#body` does.)

A `Clicksend::Client` is frozen after construction and holds no mutable state. The default
Net::HTTP adapter opens a connection per request, which costs a TLS handshake each time; for
high volumes, `adapter: [:net_http_persistent, {pool_size: 5}]` reuses connections (add the
`faraday-net_http_persistent` gem). Share one client across threads, Puma workers and Sidekiq
jobs. Loggers and instrumenters are called on the calling thread and must be thread-safe.

## Testing your application

**Stub HTTP.** Requests go through Net::HTTP by default, so [WebMock](https://github.com/bblimke/webmock) works:

```ruby
stub_request(:post, "https://rest.clicksend.com/v3/sms/send")
  .to_return(status: 200, headers: {"Content-Type" => "application/json"}, body: {
    http_code: 200, response_code: "SUCCESS", response_msg: "Messages queued for delivery.",
    data: {total_count: 1, queued_count: 1, messages: [{to: "+61411111111", message_id: "TEST-1", status: "SUCCESS"}]}
  }.to_json)
```

**Use ClickSend's test numbers.** These include `+61411111111`, `+14055555555` and `+447777777777`;
see the [full list](https://developers.clicksend.com/docs/testing). Nothing is sent or charged.
A test number only returns `SUCCESS` if its country is enabled for your account. Otherwise
ClickSend answers with the per-message status `COUNTRY_NOT_ENABLED`, which `deliver` raises as
`MessageRejected`.

**Replace the transport.** For tests that shouldn't touch HTTP at all, pass any object that
responds to `call(method, path, query:, body:, headers:)` and returns a
`Clicksend::Transport::Response`:

```ruby
FakeTransport = Struct.new(:responses) do
  def call(method, path, query:, body:, headers:) = responses.shift
end

client = Clicksend::Client.new(username: "u", api_key: "k", transport: FakeTransport.new([
  Clicksend::Transport::Response.new(status: 200, headers: {}, body: '{"data":{"balance":"5.00"}}')
]))
```

## What is covered

| Capability | API | In this gem |
|---|---|---|
| Send SMS (single, batch, lists, scheduled) | `POST /v3/sms/send` | `sms.deliver`, `sms.deliver_batch` |
| Delivery receipts | `GET /v3/sms/receipts[/{id}]`, `PUT /v3/sms/receipts-read` | `sms.receipts`, `sms.receipt`, `sms.mark_receipts_read` |
| Replies (inbound SMS) | `GET /v3/sms/inbound`, `PUT /v3/sms/inbound-read[/{id}]` | `sms.inbound`, `sms.mark_inbound_read`, `sms.mark_inbound_message_read` |
| Message history | `GET /v3/sms/history` | `sms.history` |
| Pushed receipts and replies (webhooks) | automation rules with the URL action | `Clicksend::Webhook` |
| Account balance | `GET /v3/account` | `account.fetch` |
| RCS | sent through `/v3/sms/send` once ClickSend enables it on your account | `sms.deliver` |
| Everything else | [API reference](https://developers.clicksend.com/docs/) | `client.request`, `client.paginate` |

Deliberately **not** wrapped:
- Fax and post. ClickSend no longer offers them to new customers.
- Email, payments and recharge, and reseller features.

For broad coverage, use ClickSend's official SDK. Notes on ambiguities in ClickSend's
documentation that affect this gem are in [docs/clicksend-api-notes.md](docs/clicksend-api-notes.md).

## Using it alongside the official SDK

This gem's namespace is `Clicksend`. ClickSend's official `clicksend_client` (6.x) uses
`ClickSend`. The two gems can be installed and loaded in the same application without conflicting.

## Background and design

**History.** This gem was first written in 2014 against ClickSend's v2 API, which was
form-encoded and reported errors as HTTP 200 with result codes. That version (0.0.3) no longer
loads on current Ruby or Faraday, and ClickSend has since moved to a JSON REST v3 API. In 2026
ClickSend also released a regenerated official Ruby SDK covering most of v3. Rebuilding a
second full SDK would duplicate that work, so 1.0 is a rewrite that does one thing carefully:
messaging.

**Scope.** A small set of wrapped methods returns immutable value objects for the
things messaging apps touch most: sent messages, batches, receipts, replies, the account.
Every model keeps ClickSend's full payload in `#raw`. Everything else goes through
`client.request` and `client.paginate`. These are the same code path the wrapped methods
use, not a separate low-level client. New ClickSend endpoints are therefore usable on the
day they ship, without waiting for a release of this gem.

**Architecture.**
- `Transport::Faraday` is the only file that knows about Faraday. It holds no credentials,
  and it can be replaced with any object that implements one method.
- `Connection` encodes requests, parses ClickSend's response envelope, maps statuses to
  errors, and applies the retry policy.
- `Client` validates configuration, rejects any path that could reach another host, and is
  frozen after construction.

**Not sending a message twice.** ClickSend accepts no idempotency key, so the gem decides
when a retry is safe from what it knows about each failure. That covers the HTTP status, and
whether the connection failed before or after the request could have been sent. Where it
can't tell, it doesn't retry. An end-to-end spec runs the real HTTP stack against a local
server. It shows that a send arrives exactly once after a connection close, a reset, a read
timeout, a 5xx response or a failed TLS handshake.

**Testing against the API contract.**
- **Fixtures.** Response fixtures are ClickSend's own published examples, generated from its
  OpenAPI files.
- **Contract specs** (run weekly and on pull requests) check four things: that each wrapped
  endpoint still exists, that the request bodies the gem builds validate against ClickSend's
  schemas, that the fixtures still match ClickSend's current examples, and that they conform
  to the response schemas. The places where ClickSend's own examples contradict its schemas
  are listed explicitly in the specs.
- **Live specs.** An optional suite runs against the real API, using ClickSend's free test
  numbers only.
- **API notes.** What was verified, what is ambiguous in the documentation, and what was
  observed live is recorded in [docs/clicksend-api-notes.md](docs/clicksend-api-notes.md).

## Development

```sh
bin/setup
bundle exec rake            # specs + Standard
bundle exec rake contract   # checks requests and fixtures against ClickSend's published OpenAPI files (network)
CLICKSEND_LIVE=1 CLICKSEND_USERNAME=... CLICKSEND_API_KEY=... bundle exec rspec --tag live  # optional, real API
```

The specs run against ClickSend's own documented examples (`spec/fixtures`) and never need
credentials. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE.txt](LICENSE.txt). Originally written in 2014 by Amit Solanki and Braj Pratap Singh.
