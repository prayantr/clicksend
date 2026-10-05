# clicksend

A small, focused Ruby client for the [ClickSend](https://www.clicksend.com) SMS API (REST v3).
It covers sending single and batch SMS, delivery receipts, replies and your account
balance, plus a documented way to call every other ClickSend endpoint.

> **Unofficial.** This gem is community-maintained and not affiliated with or endorsed by
> ClickSend. ClickSend publishes its own generated SDK, [`clicksend_client`](https://rubygems.org/gems/clicksend_client).
>
> **Status:** `1.0.0.rc1`, a full rewrite of the 2014 `0.0.x` gem. It has not been released to
> RubyGems yet. Upgrading from 0.0.x? Read [MIGRATING.md](MIGRATING.md). The namespace changed
> from `ClickSend` to `Clicksend`.

```ruby
client = Clicksend::Client.new(username: ENV["CLICKSEND_USERNAME"], api_key: ENV["CLICKSEND_API_KEY"])

message = client.sms.deliver(to: "+61411111111", body: "Your code is 481516", from: "Acme")
message.message_id # => "1ABC3200-C38C-6308-BE4B-C7C51D01DCF0"
```

## Contents

- [Why this gem?](#why-this-gem)
- [Installation](#installation)
- [Configuration](#configuration)
- [Sending SMS](#sending-sms)
- [Delivery receipts and replies](#delivery-receipts-and-replies)
- [Account balance](#account-balance)
- [Pagination](#pagination)
- [Errors](#errors)
- [Timeouts and retries](#timeouts-and-retries)
- [Calling other ClickSend endpoints](#calling-other-clicksend-endpoints)
- [Logging and thread safety](#logging-and-thread-safety)
- [Testing your application](#testing-your-application)
- [What is covered](#what-is-covered)
- [Using it alongside the official SDK](#using-it-alongside-the-official-sdk)
- [Development](#development)

## Why this gem?

ClickSend's official SDK is generated from their OpenAPI description and covers
almost the whole API. Use it if you need broad coverage (email, campaigns, numbers,
automations, and so on).

This gem does less on purpose. It handles the messaging core carefully:

| | `clicksend` (this gem) | `clicksend_client` (official) |
|---|---|---|
| Scope | SMS, receipts, replies, balance, plus `client.request` for any endpoint | Most of the API, generated |
| Timeouts | On by default (30s read, 5s connect) | Off by default (`timeout = 0`) |
| Retries | Built in, and never re-sends a message that may already have been accepted | None |
| Failed messages inside an HTTP 200 | `deliver` raises `MessageRejected`; `deliver_batch` exposes `#rejected` | Left for you to check |
| Pagination | `auto_paging_each` | Manual `page`/`limit` |
| Configuration | Immutable client instances | Global `Configuration.default` |
| Runtime dependencies | Faraday 2 | Typhoeus (libcurl) |

## Installation

Requires Ruby 3.3 or newer.

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
| `logger` | `nil` | Any object with `#info`/`#warn`, e.g. `Rails.logger` |
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
Each message needs `body` and exactly one of `to` or `list_id`.

## Delivery receipts and replies

ClickSend can push receipts and replies to a webhook, or you can poll for them. Polling
needs rules with the **POLL** action for SMS receipts and inbound SMS. You can set these up
in the dashboard or through the
[automations API](https://developers.clicksend.com/docs/automations/sms).

```ruby
client.sms.receipts.auto_paging_each do |receipt|
  receipt.message_id     # matches Message#message_id
  receipt.custom_string
  receipt.delivered?     # status_code 201
  receipt.failed?        # status_code 301 (see receipt.status_text / error_code)
  receipt.pending?       # status_code 200 or 300 (not final yet)
end
client.sms.mark_receipts_read(before: Time.now)

client.sms.inbound.auto_paging_each do |reply|
  reply.from
  reply.body
  reply.original_message_id  # the message this replies to
end
client.sms.mark_inbound_read(before: Time.now)       # or every unread reply, with no argument
client.sms.mark_inbound_message_read(reply.message_id) # just one
```

Status codes follow ClickSend's
[SMS error codes](https://help.clicksend.com/en/articles/42318-sms-error-codes) article.
`client.sms.receipt(message_id)` fetches a single receipt, including receipts already marked read.

> These lists contain only **unread** items. If you mark items read while paging through
> them, later pages shift and you will skip some. Process the pages first, then call
> `mark_*_read(before:)` with the time you started.

## Account balance

```ruby
account = client.account.fetch
account.balance   # => "4.998000"
account.currency  # => "AUD"
account.raw       # every field ClickSend returned
```

Every model keeps the full payload in `#raw`, so fields this gem doesn't name are still there.

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
Clicksend::Error
├── ConfigurationError        missing credentials, invalid options
├── ConnectionError           no response: DNS, refused, TLS, reset   #request_may_have_been_sent?
│   └── TimeoutError
├── APIError                  #http_status #response_code #response_msg #headers #body
│   ├── ClientError           other 4xx
│   │   ├── BadRequestError       400
│   │   ├── AuthenticationError   401
│   │   ├── ForbiddenError        403
│   │   ├── NotFoundError         404
│   │   └── RateLimitError        429   #retry_after
│   └── ServerError           5xx
├── MalformedResponseError    not JSON, or missing documented fields
└── MessageRejected           deliver: the message was refused   #status #result
```

`response_code` is ClickSend's application code, for example `INVALID_RECIPIENT`,
`INSUFFICIENT_CREDIT` or `COUNTRY_NOT_ENABLED`; see the
[list](https://developers.clicksend.com/docs/#application-status-codes). Errors keep the
original exception as `#cause`, and their messages never include your credentials.

## Timeouts and retries

Timeouts are always on (`timeout: 30`, `open_timeout: 5`). Failed requests are retried
up to `max_retries` times, with exponential backoff and jitter, **only when retrying cannot
send something twice**:

| Failure | Retried for |
|---|---|
| 429 Too Many Requests (honours `Retry-After` up to 30s) | every request: ClickSend did not process it |
| Connection refused, DNS failure, connect timeout | every request: it never reached ClickSend |
| Read timeout, connection reset, 5xx | idempotent requests only: `GET`s and the gem's mark-read calls |

ClickSend's send endpoint has no idempotency key. So a send that times out is **not**
retried, and you get a `Clicksend::TimeoutError` whose `request_may_have_been_sent?` is
`true`. The message may or may not have gone out. Before sending again, check with your own
`custom_string`:

```ruby
history = client.paginate("/v3/sms/history", query: {date_from: started_at.to_i})
already_sent = history.auto_paging_each.any? { |m| m["custom_string"] == "otp:user-42" }
```

## Calling other ClickSend endpoints

This gem wraps a small part of ClickSend's API on purpose. Everything else is available through
the same request path: same authentication, timeouts, retry rules, errors and parsing.

```ruby
response = client.request(:post, "/v3/sms/price", body: {messages: [{to: "+61411111111", body: "Hi"}]}, idempotent: true)
response.data           # the envelope's "data" (frozen Hash/Array)
response.response_code  # => "SUCCESS"
response.http_status; response.headers; response.body

client.request(:put, "/v3/sms/#{message_id}/cancel")
client.request(:get, "/v3/sms/templates", query: {page: 2})

# Any paginated list, as raw Hashes:
client.paginate("/v3/sms/history", query: {date_from: (Time.now - 7 * 86_400).to_i}).auto_paging_each { |sms| ... }
```

- Write paths exactly as in ClickSend's [API reference](https://developers.clicksend.com/docs/), starting with `/v3/`.
  Full URLs are rejected, so your credentials can't be sent to another host.
- Pass `body:` as a Hash or Array. It is sent as JSON. `query:` values that are `nil` are left out.
- Only `GET` requests are treated as idempotent. ClickSend also uses `POST` and `PUT` for actions like sending
  and buying credit. Pass `idempotent: true` only for calls that are safe to repeat.

## Logging and thread safety

With `logger:`, every HTTP attempt logs one line, plus a warning for each retry:

```
[clicksend] POST /v3/sms/send -> 200 (184ms)
[clicksend] GET /v3/sms/receipts failed (Clicksend::ServerError), retrying in 0.61s (retry 1 of 2)
```

Lines never contain credentials, query strings, request bodies or response bodies.

A `Clicksend::Client` is frozen after construction and holds no mutable state. The default
Net::HTTP adapter opens a connection per request. Share one client across threads, Puma
workers and Sidekiq jobs.

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
see the [full list](https://developers.clicksend.com/docs/testing). Requests to them succeed, but
nothing is sent or charged.

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
