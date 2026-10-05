# Migrating from clicksend 0.0.x to 1.0

> ## The namespace changed: `ClickSend` → `Clicksend`
>
> ```ruby
> ClickSend::REST::Client   # 0.0.x  (capital S)   — removed
> Clicksend::Client         # 1.0    (lower-case s)
> ```
>
> The two names differ only by one capital letter, so the change is easy to miss.
> `ClickSend` (capital S) now belongs to ClickSend's **official** SDK, `clicksend_client` 6.x.
> Code that still says `ClickSend::` fails with a `NameError`. If the official gem is also
> loaded, `ClickSend` resolves to *that* gem instead, so the errors will point at its
> namespace, which can be confusing. Search for it:
>
> ```sh
> grep -rn "ClickSend::" app lib config
> ```

1.0 is a rewrite. Nothing from 0.0.x carries over unchanged. Three things changed underneath:

- **The ClickSend API.** 0.0.x called ClickSend's legacy v2 API (`api.clicksend.com/rest/v2/*.json`).
  1.0 uses the current REST v3 API (`rest.clicksend.com/v3`).
- **Ruby and its dependencies.** 0.0.x does not load on Ruby 3.4+, and it is incompatible with Faraday 2.
- **The Ruby namespace.** See above and section 1.

Your ClickSend **username and API key keep working**. Both API versions use the same HTTP Basic credentials.

## 1. The namespace is now `Clicksend`, not `ClickSend`

```ruby
# 0.0.x
ClickSend::REST::Client.new(...)

# 1.0
Clicksend::Client.new(...)
```

The constant changed from `ClickSend` to `Clicksend`; note the lower-case **s**.

Why: in 2026 ClickSend's official Ruby SDK (`clicksend_client` 6.x) adopted `ClickSend`
as its namespace. It defines constants such as `ClickSend::VERSION`, `ClickSend::Account` and
`ClickSend::Configuration`. If this gem kept that namespace, loading both gems in one application
would crash. `Clicksend` is also the standard constant name for a gem called `clicksend`.

The `require` stays the same: `require "clicksend"`.

The `ClickSend::REST` layer is gone. There is no compatibility shim, because the old methods
returned v2 responses that the v3 API cannot produce. A shim would keep the old method names
while silently changing what they return.

Find code to update:

```sh
grep -rn "ClickSend::\|ClickSendError\|\.messages\.send\|delivery_report\|account_balance" app lib
```

## 2. Method by method

| 0.0.x | 1.0 |
|---|---|
| `ClickSend::REST::Client.new(:username => u, :api_key => k)` | `Clicksend::Client.new(username: u, api_key: k)`, or no arguments to read `CLICKSEND_USERNAME` / `CLICKSEND_API_KEY` |
| `:use_ssl => false` | Removed. HTTPS only. The option was ignored in 0.0.x anyway. |
| `client.messages.send(:to => n, :message => text)` | `client.sms.deliver(to: n, body: text)` |
| `client.messages.send(:to => "n1,n2,n3", ...)` | `client.sms.deliver_batch([{to: n1, body: t}, {to: n2, body: t}, ...])` |
| `client.messages.receive` | `client.sms.inbound` (a page of replies), then `client.sms.mark_inbound_read` |
| `client.delivery_report` | `client.sms.receipts` (a page of receipts), then `client.sms.mark_receipts_read` |
| `client.account_balance` | `client.account.fetch.balance` |
| `client.account_balance(:country => "AU")` | No v3 equivalent. For prices to a country, use `client.request(:post, "/v3/sms/price", body: {...}, idempotent: true)`. |
| `rescue ClickSend::ClickSendError` | `rescue Clicksend::Error`, or a specific subclass (see README → Errors) |
| (none) | `client.request(:get, "/v3/...")` for any endpoint 1.0 doesn't wrap |
| `client.inspect` showed the API key | It no longer does |

## 3. Send parameters

| 0.0.x (`messages.send`) | 1.0 (`sms.deliver`) | Notes |
|---|---|---|
| `:to` (comma-separated, up to 1000) | `to:` (one number) | For several recipients use `deliver_batch`; each message can then have its own body |
| `:message` | `body:` | |
| `:senderid` | `from:` | |
| `:schedule` (Unix time, or `Time` converted with `to_i`) | `schedule:` | `Time` or Integer, as before |
| `:customstring` | `custom_string:` | |
| `:messagetype => "Unicode"` | none | v3 detects Unicode automatically |
| `:return` | none | No v3 equivalent; use delivery receipts |
| unknown keys silently dropped | unknown keywords raise `ArgumentError` | |

## 4. Return values and errors

0.0.x returned the parsed v2 JSON as a Hash, whatever the HTTP status. For example:

```ruby
{"recipientcount" => 1, "messages" => [{"to" => "+61...", "messageid" => "...", "result" => "0000", "errortext" => "Success"}]}
```

Checking `result == "0000"` was left to you. A 401 or 500 response came back as an ordinary Hash, too.

1.0 returns objects and raises typed errors instead:

```ruby
# 0.0.x
response = client.messages.send(to: number, message: text)
if response["messages"].first["result"] == "0000"
  id = response["messages"].first["messageid"]
end

# 1.0
begin
  id = client.sms.deliver(to: number, body: text).message_id
rescue Clicksend::MessageRejected => e
  # e.status is ClickSend's reason, e.g. "INVALID_RECIPIENT"
rescue Clicksend::AuthenticationError
  # bad username/API key
end
```

| v2 field | v3 / 1.0 |
|---|---|
| `messageid` | `Message#message_id` |
| `result` `"0000"` | `Message#status == "SUCCESS"` (`#queued?`) |
| `result` other codes / `errortext` | `Message#status`, e.g. `"INVALID_RECIPIENT"` |
| `recipientcount` | `Batch#total_count` |

Every object keeps the complete v3 payload in `#raw`.

## 5. Polling receipts and replies

0.0.x polled v2 endpoints that relied on "Poll our server" account settings. In v3,
polling needs rules with the **POLL** action, for SMS receipts and for inbound SMS.
You can set these up in the ClickSend dashboard or through the automations API.
v3 lists only unread items. After processing them, mark them read:

```ruby
started = Time.now
client.sms.receipts.auto_paging_each { |receipt| record(receipt) }
client.sms.mark_receipts_read(before: started)
```

## 6. Requirements

| | 0.0.x | 1.0 |
|---|---|---|
| Ruby | unspecified (2014 era); fails on 3.4+ | 3.3 or newer |
| HTTP | Faraday ~> 0.9 | Faraday >= 2.0.1, < 3 |
| JSON | multi_json | Ruby's `json` |
