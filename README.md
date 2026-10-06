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
  ([`AmbiguousRequestError`](#when-a-sends-outcome-is-unknown)), and history can help you check.
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
| Call the occasional ClickSend endpoint this gem doesn't wrap (price a message, list templates, view statistics) with the same authentication, timeouts, retry rules and errors | **this gem's [`client.request`](#calling-other-clicksend-endpoints)** |
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
| `adapter` | Net::HTTP | Faraday adapter; for persistent connections see [thread safety](#logging-instrumentation-and-thread-safety) |
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
  body: "Your code is 481516",     # long messages are split; Unicode needs the account's "Autodetect" setting
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

### Cancelling a scheduled message

```ruby
message = client.sms.deliver(to: "+61411111111", body: "Your appointment is tomorrow", schedule: Time.now + 86_400)
client.sms.cancel(message.message_id) # => nil when ClickSend answers SUCCESS
```

ClickSend documents only the successful case. What it answers for a message that was already
sent, already cancelled or never existed is undocumented, so for those "no exception" doesn't
prove the message won't go out. If it matters, for example before you schedule a replacement,
check `client.sms.history(message_id: message.message_id)` for the status `"Cancelled"`.

`cancel` is not retried after a timeout or 5xx, because ClickSend documents no idempotency for it.
Such a failure raises an [`AmbiguousRequestError`](#when-a-sends-outcome-is-unknown): the message
may or may not have been cancelled. Calling `cancel` again can't send anything, but may raise even
if the first call worked; history tells you which.

There is deliberately no wrapper for `PUT /v3/sms/cancel-all`: without a `custom_string` filter it
cancels every scheduled message on the account.

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
  e.class          # => Clicksend::TimeoutError (or ServerError, ConnectionError, MalformedResponseError,
                   #    or any APIError ClickSend reported inside a 2xx answer)
  e.request        # => #<Clicksend::RequestInfo POST /v3/sms/send operation="sms.deliver" idempotent=false attempts=1>
  e.retryable?     # => false
  # Decide before sending again: check history (below), or let the user ask for a new code.
end
```

It is still the error class it was, so `rescue Clicksend::TimeoutError` keeps working.
Failures the gem treats as not processed (a refused connection, a 429, a 4xx response, or a
message ClickSend refused) are not ambiguous. Apart from the refused connection, that is an
inference from ClickSend's documentation and observed behaviour, not a guarantee. An error ClickSend reports inside a 2xx
answer is ambiguous whatever its code, because that behaviour is undocumented.

To check, search [history](#message-history) for your recipient and `custom_string`:

```ruby
records = client.sms.search_history(to: user.phone, custom_string: "otp:#{attempt.id}", sent_after: started_at)
records.any?  # true: ClickSend accepted it (records.first.status says how far it got)
              # false: nothing is known yet. This is NOT proof that it wasn't sent.
```

`search_history` asks for the recipient's history (`q=to:`) from five minutes before
`sent_after` (ClickSend doesn't say whether its date filters are inclusive or which clock they
use), reads every page, and keeps only outbound rows whose `to` and `custom_string` are exactly
yours: `custom_string` isn't a filter ClickSend offers, and it calls a filter value a "text or
keyword", not an exact match. `to` must be E.164 (`"+61411111111"`), the form history stores.
Each page of 100 rows is one request against ClickSend's undocumented rate limits.

ClickSend doesn't document how soon a sent message appears in history, keeps history for about
four months, and can de-identify recipients on request, so **an empty result is not proof that
nothing was sent**. Whether to resend is your decision: for a login code, letting the user
request another is usually safer than resending automatically. Use a `custom_string` that is
unique to the message (not to the attempt), so a match from an earlier attempt counts.

## Delivery receipts and replies

ClickSend can push receipts and replies to a [webhook](#webhooks), or you can poll for them.
Polling needs rules with the **POLL** action for SMS receipts and inbound SMS. You can set these
up in the dashboard or through the
[automations API](https://developers.clicksend.com/docs/automations/sms). ClickSend's test
numbers produced no receipt in our live check, and ClickSend's legacy v2 docs say none are generated.

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
`client.sms.receipt(message_id)` fetches a single receipt, including receipts already marked read
(as ClickSend documents).

> These lists contain only **unread** items, and listing doesn't mark anything read. If you mark
> items read while paging through them, later pages shift and you will skip some. Process the
> pages first, then call `mark_*_read(before:)` with the time you started (not "now": a receipt
> reported after you listed would also be covered by a later cutoff). Without `before:`,
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
    TrackDeliveryJob.perform_later(receipt.message_id, receipt.status_code) # idempotent on both
    head :ok
  rescue Clicksend::Webhook::InvalidPayload
    head :bad_request
  end
end
```

`Webhook.parse_inbound(params)` returns a `Clicksend::SMS::InboundMessage`, and `Webhook.parse`
works out which of the two it was given. Pass the body parameters, not the route ones, so your
secret isn't kept in `#raw`.

> **Experimental.** ClickSend's current docs don't define the push format, and no real push has
> been captured for this gem yet. The field names come from ClickSend's polling API, which an
> archived ClickSend help article and ClickSend's own n8n and Power Automate integrations agree
> with. The `Clicksend::Webhook` API may change in a minor release.

**ClickSend's current docs describe no way to authenticate webhooks**: no signature, HMAC or shared
secret. An archived help article listed six source IP addresses, but it is no longer published and
was last updated years ago, so don't build an allowlist on it. Treat anyone who learns the URL as
able to send a fake receipt. This gem therefore offers no "verify" method. Instead:
- put an unguessable secret in the URL, compare it in constant time, and use HTTPS (archived
  ClickSend help says the certificate chain must be valid). A secret in the path appears in access
  logs: Rails' request log shows the path as is (Rails 8.1 filters only query parameters, such as
  `?token=`), and proxies and APM tools often keep the full URL. Restrict who can read them, and
  add the personal fields (`body`, `message`, `from`, `to`, `sms`, `originalsenderid`,
  `original_body`, `originalmessage`) to `filter_parameters`;
- to rotate the secret, accept the old and the new one until every rule uses the new URL;
- treat a push as a hint. A receipt can probably be confirmed with `client.sms.receipt(message_id)`
  (not yet verified for an account with only URL rules), at one API call per check. An
  inbound message can't be fetched by its ID through any wrapped or verified endpoint; the closest
  check is `client.sms.history(from: number)`. Be careful acting on unconfirmed replies such as
  "STOP";
- handle pushes idempotently. Several rules can match (up to 10 per inbound message, and
  integrations such as Zapier create their own rules), and a non-200 or slow answer is retried:
  ClickSend's archived pages say either every 10 minutes up to 10 times, or with backoff over hours.
  An inbound `message_id` is unique. A sent message may get more than one receipt (the pending
  codes 200 and 300 can change), so key receipts on `message_id` and `status_code`, and don't let a
  pending receipt overwrite a final one (`delivered?` or `failed?`);
- answer 200 quickly and do the work in a job. If the job parses or confirms the push, add
  `discard_on Clicksend::Webhook::InvalidPayload` below any `retry_on Clicksend::Error`: a payload
  that can't be parsed won't parse on a retry.

```ruby
# Two secrets during a rotation; ActiveSupport's secure_compare also handles different lengths.
def valid_secret?(given)
  secrets = Rails.application.credentials.clicksend_webhook_secrets # e.g. [new, old]
  secrets.any? { |secret| ActiveSupport::SecurityUtils.secure_compare(given.to_s, secret) }
end

# Deduplicating receipts in a job: one row per message, final statuses win.
# (Unique index on sms_deliveries.message_id.)
def record(receipt)
  delivery = SmsDelivery.create_or_find_by!(message_id: receipt.message_id)
  return if delivery.final? && receipt.pending? # final?: your own check for status_code 201 or 301

  delivery.update!(status_code: receipt.status_code, reported_at: receipt.reported_at)
end
```

Inbound rules post form fields by default, or use a query string (`webhook_type: "get"`) or JSON
(`"json"`); for JSON, pass `JSON.parse(request.raw_post)` or Rails' parsed body parameters. Receipt
pushes are form-encoded according to ClickSend's archived help. According to the same sources,
pushes also carry `user_id` and legacy duplicates (`message`, `sms`, `originalsenderid`,
`messageid`, `customstring`, ...), which are kept in `#raw`, and a JSON push may send `timestamp`
and `user_id` as numbers; either form is accepted. The parsers reject payloads with too many fields, oversized
or non-UTF-8 values, or nested values in the fields they read. Pass a plain Hash of the body
parameters rather than Rails' `params`, which also holds route parameters.

Some things a receiver should expect, according to ClickSend's archived help: the same receipt
format is used for voice, email and fax receipts (check `receipt.message_type` if those rules share
your URL), and an inbound MMS arrives through the SMS inbound rules with its attachment as a link
that expires after 7 days. To see a push without sending an SMS, the dashboard's **Add Test Reply**
button on a rule posts an example to its URL.

## Message history

```ruby
client.sms.history(date_from: Time.now - 86_400, to: "+61411111111").auto_paging_each do |record|
  record.direction      # "out" (sent) or "in" (received)
  record.status         # "Sent", "Completed", "Failed", "Scheduled", ... (history statuses)
  record.status_code    # the gateway code receipts use: 201 delivered, 301 failed; may be nil
  record.custom_string
end
```

For this endpoint ClickSend documents a single `q=field:value` filter. Its general search
documentation also describes several comma-separated fields with an `operator`, but not for history,
and that hasn't been verified here. So `history` takes at most one of `to:`, `from:`, `status:` and
`message_id:`, plus `date_from:`, `date_to:` and `order:` (`:asc` or `:desc`). `custom_string` isn't
a documented filter; match it yourself, or use [`search_history`](#when-a-sends-outcome-is-unknown).

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

- `#request` is a `Clicksend::RequestInfo`: `http_method`, `path` (never the query string),
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
| 429 Too Many Requests (waits for `Retry-After` if it is 30s or less) | every request: documented as "cannot be served" |
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
headers are undocumented, but when they are present you can read them (**experimental**:
`Clicksend::RateLimit` may change in a minor release if ClickSend changes the headers):

```ruby
response = client.request(:get, "/v3/account")
response.rate_limit  # => #<data Clicksend::RateLimit limit=20, remaining=19, reset_in=60>, or nil
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

Job runners retry failed jobs and re-run interrupted ones, and either can turn a send whose outcome
is unknown into a second SMS. The measurements in this section come from experiments with
ActiveJob 8.1.4, Sidekiq 8.1.7 and ActiveRecord 8.1.4 (SQLite) against local stand-ins for
ClickSend, not from ClickSend itself.

### A send job

Two rules keep a send job as safe as the gem can make it:
- **Never let an ambiguous send be retried**, and make sure nothing after it raises.
- **Other failed sends may be retried.** The gem treats them as not processed: refused
  connections, 429s, 4xx responses and per-message rejections. For 4xx and rejections that is
  how ClickSend behaves in practice, not something it documents.

```ruby
class SendSmsJob < ApplicationJob
  self.log_arguments = false # don't put phone numbers or message text in job logs

  # Rails checks these from the bottom up, so the more specific rule comes last.
  retry_on Clicksend::Error, attempts: 5, wait: :polynomially_longer # treated as not processed
  discard_on Clicksend::MessageRejected                               # ClickSend refused the message itself

  def perform(notification_id)
    notification = Notification.find(notification_id)
    CLICKSEND_JOBS.sms.deliver(to: notification.phone, body: notification.text, custom_string: "notification:#{notification_id}")
  rescue Clicksend::AmbiguousRequestError
    # The message may have gone out. Hand over to reconciliation, and make sure nothing here
    # raises: an exception would make the job runner retry the send.
    begin
      ReconcileSmsJob.perform_later(notification_id) # e.g. checks sms.search_history for the reference
    rescue => e
      Rails.logger.error("SMS for notification #{notification_id}: outcome unknown, reconciliation not enqueued (#{e.class})")
    end
  end
end
```

`CLICKSEND_JOBS` is a client with a shorter timeout, explained under
[the timeout budget](#the-timeout-budget). Ambiguous errors are rescued inside `perform`, so
`retry_on` only sees errors the gem treats as not processed.

**Declaration order matters.** `retry_on` and `discard_on` declare `rescue_from` handlers, which
Rails tries from the bottom up, a job's own before those it inherits. For a send that timed out
after ClickSend had accepted it:

| The job declares | Messages sent |
|---|---|
| only `retry_on Clicksend::Error` | 2 |
| the recipe above | 1 |
| `retry_on Clicksend::Error`, then `discard_on Clicksend::AmbiguousRequestError` | 1 |
| the same two lines in the opposite order | **2** |
| `discard_on Clicksend::AmbiguousRequestError`, under a `retry_on StandardError` inherited from `ApplicationJob` | 1 |

`discard_on` accepts the `AmbiguousRequestError` module, so it works when it is declared last.
But moving one line breaks it silently, and a discarded job reconciles nothing unless you give
`discard_on` a block. Rescuing inside `perform` doesn't depend on order.

**Retry layers stack.** When `retry_on` runs out of attempts it re-raises the error, and the queue
backend then retries the job under its own policy (Sidekiq: 25 retries by default). Attempts
multiply: with a persistent 429, `retry_on Clicksend::Error, attempts: 2` made 6 HTTP requests
(2 job runs, each with the gem's 3 attempts) before the error reached the backend. On Sidekiq's
ActiveJob adapter, a job that did *not* rescue an ambiguous error sent twice under
`retry_on attempts: 2`, and was then in Sidekiq's retry set, ready to send a third time. Keep
ambiguous errors inside `perform`, and pass `retry_on` a block if the backend shouldn't retry after
it: with a block, `retry_on` calls it instead of re-raising.

### The timeout budget

When a job runner stops (a deploy, a scale-down), it waits a limited time for running jobs, then
puts the unfinished ones back on the queue. A send still waiting for ClickSend's answer then runs
again, and the gem never sees how the first attempt ended. A real Sidekiq 8.1.7 process stopped
mid-send with `-t 2` re-queued the recipe's job, and the message was received **twice** with the
gem's default 30s read timeout. With `timeout: 1`, the send timed out first, the recipe handled the
ambiguous error, and the message was received once.

So give jobs a client whose attempts end well inside the runner's shutdown timeout:

```ruby
# config/initializers/clicksend.rb
CLICKSEND = Clicksend::Client.new(logger: Rails.logger, instrumenter: ActiveSupport::Notifications)
# Sidekiq waits 25s by default (-t, :timeout). One attempt here takes at most about 5s to connect
# plus 15s to answer, and max_retries: 0 leaves not-processed failures to retry_on.
CLICKSEND_JOBS = CLICKSEND.with(timeout: 15, max_retries: 0)
```

- The window that matters runs from sending the request to reading the answer. A worker stopped
  while connecting or backing off has sent nothing, so its re-run sends once. Retries inside the
  gem add attempts, each with its own window: keep their total inside the budget too, or turn
  them off as above.
- Sidekiq's 25 seconds comes from its source (8.1.7), and the duplicate was measured with Sidekiq.
  Other limits were not tested here: Solid Queue's README gives a default `shutdown_timeout` of
  5 seconds; Kubernetes (`terminationGracePeriodSeconds`) and Heroku limit how long a stopping
  process may run; queues with a visibility timeout redeliver a job that runs longer than it.
  Check yours, and raise it rather than cutting the client's timeout below what ClickSend needs.
- A shorter timeout turns more slow sends into ambiguous ones: more reconciliation, never a
  duplicate.

**Never wrap a send in `Timeout.timeout`.** It interrupts the thread at an arbitrary point, which can
be after ClickSend has already received the message, and raises a plain `Timeout::Error`. That isn't
a `Clicksend::Error` and isn't marked ambiguous, so neither the gem nor the recipe above can tell
that the message may have gone out, and a job runner will retry the job and may send it twice. Use
the client's own timeouts instead: a read timeout then raises an ambiguous `Clicksend::TimeoutError`
that the recipe handles.

### Marking a send in flight

A killed process (SIGKILL, out of memory, a lost host), a recovered job or a double enqueue re-runs
a job however the timeouts are set, and the recipe can't see the first run. If a duplicate matters,
record that the send is in flight **before** calling `deliver`, on the row that already represents
the message in your database, and let a run that finds that mark reconcile instead of sending. The
gem can't do this for you: only your database knows which jobs started. With a worker that died
after ClickSend had accepted the message:

| Approach | Messages sent |
|---|---|
| the recipe alone | 2 |
| claim and send inside one database transaction | **2**: the dying worker's rollback erased the claim |
| a conditional `UPDATE`, committed before `deliver` | 1; the re-run found the claim and sent nothing |
| the same, with 4 runs of one job at once | 1 |

The recipe with a marker:

```ruby
# notifications: sms_state (string, default "pending"), sms_claimed_at, sms_message_id
class SendSmsJob < ApplicationJob
  self.log_arguments = false
  retry_on Clicksend::Error, attempts: 5, wait: :polynomially_longer # sees only failures that were not processed

  def perform(notification_id)
    # The claim commits on its own: never call this inside a transaction that also covers deliver.
    claimed = Notification.where(id: notification_id, sms_state: "pending")
      .update_all(sms_state: "sending", sms_claimed_at: Time.current) == 1
    return unless claimed # done, failed, or another run is sending (or died sending): never send here

    notification = Notification.find(notification_id)
    message = CLICKSEND_JOBS.sms.deliver(to: notification.phone, body: notification.text, custom_string: "notification:#{notification_id}")
    notification.update_columns(sms_state: "sent", sms_message_id: message.message_id)
  rescue Clicksend::AmbiguousRequestError
    Notification.where(id: notification_id).update_all(sms_state: "unknown") # reconciled later, never resent here
  rescue Clicksend::MessageRejected
    Notification.where(id: notification_id).update_all(sms_state: "failed")
  rescue Clicksend::Error
    Notification.where(id: notification_id, sms_state: "sending").update_all(sms_state: "pending") # not processed
    raise # release the claim, and let retry_on try again
  end
end
```

Anything that fails after the claim, including the updates in the `rescue` clauses, leaves the row
`sending`, and a re-run then sends nothing: the safe direction. A 429 that outlasted the gem's
retries released the claim, and the job's retry sent the message once.

### Reconciling with history

With the marker, reconciliation needs no hand-over: rows left `sending` or `unknown` are the
work list. Check them with [`search_history`](#when-a-sends-outcome-is-unknown) from a recurring
job, not straight after the failure: ClickSend doesn't say how soon a sent message appears in
history.

```ruby
# Run every few minutes (e.g. a Solid Queue recurring task or a cron job).
class SmsReconciliationJob < ApplicationJob
  def perform
    Notification.where(sms_state: %w[sending unknown]).where("sms_claimed_at < ?", 10.minutes.ago).find_each do |notification|
      found = CLICKSEND.sms.search_history(to: notification.phone, custom_string: "notification:#{notification.id}",
        sent_after: notification.sms_claimed_at)
      if found.any?
        notification.update_columns(sms_state: "sent", sms_message_id: found.first.message_id)
      elsif notification.sms_claimed_at < 1.day.ago
        notification.update_columns(sms_state: "unresolved") # for a person to decide
      end
    end
  end
end
```

Not finding the message is **not** a reason to resend it: an empty result doesn't prove that
nothing was sent. Keep checking for a while, then let a person or the user decide (for a login
code, the user asking for a new one is usually safer). Each check reads at least one page of
history, against ClickSend's undocumented rate limits.

### Sidekiq without ActiveJob

The recipe works the same way in a `Sidekiq::Job`. Sidekiq can also stop an ambiguous error that
escapes `perform` from being retried:

```ruby
class SendSmsWorker
  include Sidekiq::Job

  # Safety net: an ambiguous error goes to the Dead set instead of being retried.
  sidekiq_retry_in { |_count, error, _job| :kill if error.is_a?(Clicksend::AmbiguousRequestError) }
  sidekiq_retries_exhausted { |job, error| Sidekiq.logger.warn("#{job["class"]} #{job["jid"]} gave up: #{error.class}") }

  def perform(notification_id)
    # as SendSmsJob#perform above: rescue Clicksend::AmbiguousRequestError and reconcile
  end
end
```

In Sidekiq 8.1.7 (measured with a real Sidekiq process, and read in its source):
- `:kill` puts the job in the Dead set and calls `sidekiq_retries_exhausted` and the death
  handlers. **Pressing "Retry Now" on that dead job runs the send again**: reconcile first.
- `:discard` drops the job and calls only the death handlers, so nothing is left in the Web UI to
  investigate.
- `nil` keeps the normal retry schedule.

Prefer rescuing inside `perform` and keep `:kill` as the safety net. `sidekiq_retries_exhausted`
also runs when the ordinary retries run out.

## Calling other ClickSend endpoints

This gem wraps a small part of ClickSend's API on purpose. Everything else is available through
the same request path: same authentication, timeouts, retry rules, errors and parsing.

```ruby
response = client.request(:post, "/v3/sms/price", body: {messages: [{to: "+61411111111", body: "Hi"}]}, operation: "sms.price")
response.data           # the envelope's "data" (frozen Hash/Array)
response.response_code  # => "SUCCESS"
response.http_status; response.headers; response.body

client.request(:get, "/v3/statistics/sms", operation: "statistics.sms")
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
  # => {http_method: :post, path: "/v3/sms/send", operation: "sms.deliver", idempotent: false,
  #     attempts: 1, http_status: 200, response_code: "SUCCESS", ambiguous: false}
end
```

| Event | When | Payload |
|---|---|---|
| `request.clicksend` | around each call, retries included | `http_method`, `path`, `operation`, `idempotent`; on completion `attempts`, `http_status` (nil without a response), `response_code`, `ambiguous`. ActiveSupport adds `exception` on failure |
| `retry.clicksend` | before each retry | `http_method`, `path`, `operation`, `attempt` (1 for the first retry), `delay`, `error_class`, `http_status` |

Payloads never contain credentials, headers, query strings or bodies, and the wrapped methods' paths
contain no phone numbers or message text. Paths and `operation:` labels you pass to `client.request`
are reported as you wrote them, minus any query string or fragment. (An exception object attached
by ActiveSupport carries the response body of an API error, as `#body` does.)

**Structured logs.** For `key=value` or JSON logs, subscribe to both events and keep the fields you
want:

```ruby
ActiveSupport::Notifications.subscribe(/\.clicksend\z/) do |event|
  p = event.payload
  fields = {event: event.name, operation: p[:operation], method: p[:http_method], path: p[:path],
            status: p[:http_status], code: p[:response_code], attempts: p[:attempts], ambiguous: p[:ambiguous],
            attempt: p[:attempt], delay: p[:delay], error: p[:error_class] || p.dig(:exception, 0),
            duration_ms: event.duration.round(1)}.compact
  Rails.logger.info(fields.map { |key, value| "#{key}=#{value}" }.join(" "))
end
# event=request.clicksend operation=sms.deliver method=post path=/v3/sms/send status=200 code=SUCCESS attempts=1 ambiguous=false duration_ms=184.2
# event=request.clicksend operation=sms.deliver method=post path=/v3/sms/send attempts=1 ambiguous=true error=Clicksend::TimeoutError duration_ms=15001.7
```

**Metrics.** Label by `operation` and an outcome, **never by `path`**: paths such as
`/v3/sms/receipts/{message_id}` contain IDs, so every message would create new series.

```ruby
ActiveSupport::Notifications.subscribe("request.clicksend") do |event|
  p = event.payload
  outcome = if p[:ambiguous] then "ambiguous" # may have been processed: reconcile
  elsif p[:exception] then "error"
  else "ok" # MessageRejected is raised after this event, where you call deliver
  end
  tags = {operation: p[:operation] || "other", outcome: outcome}

  StatsD.distribution("clicksend.request.duration", event.duration, tags: tags)  # statsd-instrument, milliseconds
  # prometheus-client: REQUEST_SECONDS.observe(event.duration / 1000.0, labels: tags)
  # Yabeda:            Yabeda.clicksend.request_duration.measure(tags, event.duration / 1000.0)
end
```

Alert on `outcome=ambiguous` (each one is a send to reconcile) and on `retry.clicksend` events whose
`error_class` is `Clicksend::RateLimitError`.

**Rails 8.1 structured events.** The events plug into `Rails.event` through a
`StructuredEventSubscriber` (`retry` is a legal method name):

```ruby
# config/initializers/clicksend.rb
class ClicksendEvents < ActiveSupport::StructuredEventSubscriber
  def request(event)
    emit_event("clicksend.request", event.payload.slice(:operation, :http_status, :response_code, :attempts, :ambiguous)
      .merge(duration_ms: event.duration.round(2)))
  end

  def retry(event)
    emit_event("clicksend.retry", event.payload.slice(:operation, :attempt, :delay, :error_class, :http_status))
  end
end
ClicksendEvents.attach_to :clicksend
```

**OpenTelemetry.** Generic HTTP instrumentation works below this gem and records the request URL
with its query string, which this gem keeps out of its own logs, errors and events. For
`sms.history(to:)` and `sms.search_history`, that is the recipient's phone number. With
`opentelemetry-instrumentation-faraday` 0.33.0 the span (named just `GET`) recorded
`url.full=https://rest.clicksend.com/v3/sms/history?order_by=date%3Aasc&q=to%3A%2B61411111111`;
`opentelemetry-instrumentation-net_http` 0.29.1 records the same query as `url.query`. Both also
send a `traceparent` header to ClickSend. With those versions:
- the Net::HTTP instrumentation skips ClickSend with `untraced_hosts: ["rest.clicksend.com"]`;
- the Faraday instrumentation has no such option. Don't enable it, or wrap ClickSend calls in
  `OpenTelemetry::Common::Utilities.untraced { ... }`, which suppresses every span inside the block.

For ClickSend spans without that problem, use
[`clicksend-opentelemetry`](companions/clicksend-opentelemetry): one span per call, with retries
as events and ambiguity as an attribute, and never a query string, body or phone number. It is
available in this repository and released separately from this gem, on its own version line; it
is not on RubyGems yet.

**Thread safety.** A `Clicksend::Client` is frozen after construction and holds no mutable state.
Share one client across threads, Puma workers and Sidekiq jobs. Loggers and instrumenters are
called on the calling thread and must be thread-safe.

**Persistent connections.** The default Net::HTTP adapter opens a connection per request, which
costs a TCP and TLS handshake each time. The `faraday-net_http_persistent` gem reuses connections.
In a local benchmark (a loopback TLS server adding a simulated 25 ms round trip; ClickSend's own
latency wasn't measured), the median send took 31 ms instead of 84 ms, and 8 threads used one
connection each instead of one per request.

```ruby
threads = ENV.fetch("RAILS_MAX_THREADS", 5).to_i # every thread that shares this client
CLICKSEND = Clicksend::Client.new(adapter: [:net_http_persistent, {pool_size: threads}])
```

The pool must be **at least as large as the number of threads sharing the client** (Puma's
threads, Sidekiq's concurrency). A thread that can't get a connection in time fails with a timeout,
and a send that fails that way may be reported as ambiguous although nothing was sent: in the same
local benchmark, 31 of 400 sends from 8 threads sharing `pool_size: 2` failed this way. With this adapter,
a refused connection or connect timeout may also be reported as possibly sent. None of these sends
anything twice, but each can leave a message unsent that the default adapter would have retried,
and gives you a send to reconcile. Build the client once (`with` creates a new pool), and note that
this adapter isn't part of this gem's test suite.

## Testing your application

**Use the in-memory ClickSend.** `require "clicksend/testing"` (not loaded by default) adds
`Clicksend::Testing::FakeAPI`. It replaces only the HTTP exchange, so your code runs against a
real `Clicksend::Client`: argument validation, errors, retry rules and models are the production
code paths. Nothing is sent and no network is used.

```ruby
require "clicksend/testing"

fake = Clicksend::Testing::FakeAPI.new
client = fake.client # a real Clicksend::Client using the fake; retries don't wait

client.sms.deliver(to: "+61411111111", body: "Your code is 481516", custom_string: "otp:42")
fake.sent_messages.map { |m| [m.to, m.custom_string] } # => [["+61411111111", "otp:42"]]
fake.requests.last.path                                # => "/v3/sms/send" (headers are never kept)

fake.reject(to: "+61400000000", status: "INVALID_RECIPIENT") # deliver raises MessageRejected
fake.add_receipt(for: fake.sent_messages.last, status_code: 201)
fake.add_inbound(reply_to: fake.sent_messages.last, body: "STOP")
fake.stub(:get, "/v3/sms/templates") { |request| {"data" => {"data" => []}} } # any other endpoint
fake.reset!
```

In your app, inject `fake.client` where you would use your real client. If your code builds its
own client, give it the fake as its transport, with placeholder credentials and a retry policy
that doesn't wait:

```ruby
Clicksend::Client.new(username: "test", api_key: "test", transport: fake,
  retry_policy: Clicksend::RetryPolicy.new(base_delay: 0, max_delay: 0))
```

**Simulate failures, including the ambiguous ones.** For outcomes where it matters you must say
whether ClickSend processed the request before the failure, which is exactly the question your
code has to cope with:

```ruby
fake.fail_next(:timeout, processed: true)   # accepted, response lost: deliver raises AmbiguousRequestError, one message recorded
fake.fail_next(:timeout, processed: false)  # never processed: same error, nothing recorded
fake.fail_next(:connection_reset, processed: true)
fake.fail_next(status: 500, processed: false)
fake.fail_next(:connection_refused)         # never sent: the gem retries it transparently
fake.fail_next(status: 429, retry_after: 0) # rate limited: retried
fake.fail_next(status: 401)
fake.fail_next(:timeout, processed: true, path: "/v3/sms/send", times: 2) # only matching requests
```

The fake also serves receipts, replies (marked read as ClickSend documents; whether the cutoff is
inclusive is the fake's guess) and the account. Exceptions raised by your stub blocks surface as
`Clicksend::Testing::StubError`, never as a simulated ClickSend failure.

It deliberately **doesn't serve history by itself**: ClickSend doesn't say how soon a sent message
appears there, and an always-current fake history would let a "not in history, so resend" rule
pass its tests and send twice in production. Say what history shows at each point of your test:

```ruby
fake.stub_history                                              # nothing (yet)
fake.stub_history(fake.sent_messages.last)                     # this message, status "Sent"
fake.stub_history(fake.sent_messages.last, status: "Cancelled")
```

Every history request then gets exactly those rows, whatever its filters.

`client.sms.cancel` works on a message the fake accepted with a schedule still in the future, and
the message then appears in `fake.cancelled_messages` (it stays in `sent_messages`). ClickSend
doesn't document what it answers for any other message, so the fake raises `StubError` instead of
guessing; `fake.stub(:put, "/v3/sms/#{id}/cancel") { ... }` states the answer your test assumes.

The fake simplifies, so don't let your tests depend on these:
- Recipients that aren't 6 to 15 digits (optionally after `+`) get `INVALID_RECIPIENT`; ClickSend's
  own rules decide in reality. It never answers `THROTTLED`, and test numbers always succeed.
- The balance never changes, and message parts are estimated.

It can stand in as a development "dry run" transport too.

**Stub HTTP.** Requests go through Net::HTTP by default, so [WebMock](https://github.com/bblimke/webmock) also works:

```ruby
stub_request(:post, "https://rest.clicksend.com/v3/sms/send")
  .to_return(status: 200, headers: {"Content-Type" => "application/json"}, body: {
    http_code: 200, response_code: "SUCCESS", response_msg: "Messages queued for delivery.",
    data: {total_count: 1, queued_count: 1, messages: [{to: "+61411111111", message_id: "TEST-1", status: "SUCCESS"}]}
  }.to_json)
```

**Use ClickSend's test numbers** for checks against the real API. These include `+61411111111`,
`+14055555555` and `+447777777777`; see the [full list](https://developers.clicksend.com/docs/testing).
Nothing is sent or charged, and no delivery receipt is generated. A test number only returns
`SUCCESS` if its country is enabled for your account. Otherwise ClickSend answers with the
per-message status `COUNTRY_NOT_ENABLED`, which `deliver` raises as `MessageRejected`.

**Write your own transport** if you need to: any object that responds to
`call(method, path, query:, body:, headers:)` and returns a `Clicksend::Transport::Response`.

## What is covered

| Capability | API | In this gem |
|---|---|---|
| Send SMS (single, batch, lists, scheduled) | `POST /v3/sms/send` | `sms.deliver`, `sms.deliver_batch` |
| Delivery receipts | `GET /v3/sms/receipts[/{id}]`, `PUT /v3/sms/receipts-read` | `sms.receipts`, `sms.receipt`, `sms.mark_receipts_read` |
| Replies (inbound SMS) | `GET /v3/sms/inbound`, `PUT /v3/sms/inbound-read[/{id}]` | `sms.inbound`, `sms.mark_inbound_read`, `sms.mark_inbound_message_read` |
| Cancel a scheduled SMS | `PUT /v3/sms/{message_id}/cancel` | `sms.cancel` |
| Message history | `GET /v3/sms/history` | `sms.history`, `sms.search_history` |
| Pushed receipts and replies (webhooks) | automation rules with the URL action | `Clicksend::Webhook` |
| Account balance | `GET /v3/account` | `account.fetch` |
| Testing without the network | | `Clicksend::Testing::FakeAPI` |
| RCS | sent through `/v3/sms/send` once ClickSend enables it on your account | `sms.deliver` |
| Everything else | [API reference](https://developers.clicksend.com/docs/) | `client.request`, `client.paginate` |

Deliberately **not** wrapped:
- Fax and post. ClickSend no longer offers them to new customers.
- Email, payments and recharge, and reseller features.
- Price quotes (`POST /v3/sms/price`). ClickSend says a quote sends no message, but not that it
  is free of other effects (it returns a `message_id`); call it through `client.request`, which
  treats it as not safe to repeat.
- Cancelling every scheduled message (`PUT /v3/sms/cancel-all`).

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
