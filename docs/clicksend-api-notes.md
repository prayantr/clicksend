# ClickSend API notes

How this gem interprets ClickSend's REST v3 documentation, where that documentation is
ambiguous, and what the live API actually did. Last reviewed 2026-10-06: the documentation
review covered all 34 OpenAPI sections, and the live runs on 2026-10-05 and 2026-10-06 (see
"Live verification") covered sending and read-only history and rate-limit checks, but no
delivery receipt.

Sources:
- [API reference](https://developers.clicksend.com/docs/), with its OpenAPI files at
  `https://developers.clicksend.com/docs/_spec/<section>.yaml`
- [Testing](https://developers.clicksend.com/docs/testing)
- [SMS error codes](https://help.clicksend.com/en/articles/42318-sms-error-codes)
- Superseded but still informative: the [legacy HTTP v2 docs](https://developers.clicksend.com/docs/http/v2/)
  and the [archived REST v3 docs](https://web.archive.org/web/20220502204655/https://developers.clicksend.com/docs/rest/v3/)
  (2022), and help articles that disappeared when ClickSend moved its help centre (around mid-2025,
  judging by the Wayback Machine, which kept them). Those, and ClickSend's own integrations, are the only sources that list
  the fields ClickSend pushes to webhook URLs; see `research/1.2-webhooks.md` in the repository

## Behaviour taken from the documentation

| Topic | Documented behaviour | Gem behaviour |
|---|---|---|
| Base URL and auth | `https://rest.clicksend.com/v3`, HTTP Basic with username and API key | Same |
| Envelope | `{http_code, response_code, response_msg, data}` | Parsed into `Response`; `response_code`/`response_msg` exposed on errors |
| HTTP statuses | 200, 201, 204, 400, 401, 403, 404, 405, 429, 500 | Mapped to the error hierarchy |
| Per-message status | `/sms/send` `http_code` "doesn't reflect the status of each message" | `MessageRejected` (single) / `Batch#rejected` |
| Pagination | `page` (default 1) and `limit` (default 15, min 15, max 100); `total`, `per_page`, `current_page`, `last_page` | `Page`; `limit` checked against 15..100 |
| Receipt status codes | 200 sent/queued, 201 delivered, 300 temporary failure (ClickSend retries), 301 failed | `pending?` / `delivered?` / `failed?` |
| Unread-only lists | Receipts and inbound marked read "won't be shown" in the list endpoints. Listing does not mark anything read (archived docs) | Documented in the README (paging pitfall) |
| POLL rules | Polling receipts and inbound requires a rule with the POLL action | Documented |
| Mark-read cutoff | `date_before`, Unix timestamp, optional. Without it, **everything** is marked read ("mark all", and the archived "If not given, all messages will be marked as read") | `before:` (Time or Integer); `{}` when omitted. Since 1.1 retried only with a cutoff (see "Retry safety") |
| Per-receipt mark-read | None: receipts can only be marked read by cutoff. Inbound messages have `PUT /v3/sms/inbound-read/{message_id}` | `mark_inbound_message_read` only |
| Unicode | Detected automatically **if** the account's dashboard setting is "Autodetect" (help 42194); no `messagetype` in v3 | Not exposed |
| URLs in SMS | Paused for new customers pending approval | Documented |
| Test numbers | e.g. `+61411111111`: "No messages will be sent, and your account won't be charged". The legacy v2 docs add: "A delivery report won't be generated when using a test number" | Used by the live specs. **Live:** still subject to the account's enabled countries, and no receipt (see below) |
| Idempotency | No idempotency key on any operation (all 34 sections searched) | Sends are never retried after timeouts or 5xx |
| `THROTTLED` | Application code: "Identical message body recently sent to the same recipient." Window and placement undocumented | Treated as an ordinary rejection; never relied on for deduplication |
| History search | `GET /v3/sms/history`: `date_from`, `date_to`, `order_by` (`date:asc` default), `page`, `limit`, and `q=field:value` for `status`, `to`, `from`, `subaccount_id`, `message_id`. `custom_string` is **not** a filter | `sms.history` takes one of `to:`, `from:`, `status:`, `message_id:`; match `custom_string` yourself |
| Combining search filters | The general "Searching and Sorting" section shows `q=field:value,field2:value`, `AND` by default, and `operator=OR`; searches are "**not** case-sensitive". The history operation itself documents one `field_name:value` and no `operator`, and calls the value "the text or keyword you're searching for" (exact or partial match unstated) | `sms.history` sends one filter; `sms.search_history` re-checks `to` and `custom_string` for exact equality |
| History retention | Help 43125: message data is kept for four months, then archived and "no longer available to view in the Dashboard, or downloadable from the History page or API". De-identification (on request) obfuscates `to` "in any history downloads" | Another reason an empty history search proves nothing |
| History consistency | **None documented**: no statement anywhere (current, archived or help) on how soon an accepted send appears in `GET /v3/sms/history` | `search_history` returns rows only; never "not sent" |
| Cancel one scheduled SMS | `PUT /v3/sms/{message_id}/cancel`, no body; 200 example `response_msg: "Scheduled sms message has been cancelled."`, `data` "deprecated and will return null" (archived 2022: `data: []`, message naming the ID). Answers for an unknown, sent or already-cancelled ID, and idempotency, are **undocumented** | `sms.cancel`, not idempotent: never retried after a timeout or 5xx |
| Cancel all scheduled SMS | `PUT /v3/sms/cancel-all`; optional body `custom_string` limits it to messages with that value (match semantics undocumented); without it, every scheduled SMS is cancelled. Returns `data.count` | Deliberately not wrapped |
| Price quote | `POST /v3/sms/price`: "calculate the price of sending messages". The only statement about effects is in the `sms` schema's `date`: it may be empty "in price-calculation responses where no message has actually been sent yet". The example returns a `message_id` | Not wrapped; `client.request` treats it as non-idempotent |
| Webhooks (push) | Automation rules with the `URL` action. Inbound rules: `webhook_type` `post` (form, default), `get` or `json` (format unspecified; ClickSend's n8n trigger shows a flat JSON object with integer `timestamp`/`user_id`). Receipts: form-encoded POST according to archived help ("the only forwarding format we support is x-www-form-urlencoded"). **No payload schema** in the current docs; archived docs and help list the fields: the poll schemas' names plus `user_id`, `status` (receipts) and legacy duplicates (`message`, `sms`, `originalsenderid`, `originalmessage`, `originalmessageid`, `customstring`, `messageid`). Retries: archived sources disagree (every 10 minutes ×10 with a 30 s timeout, or backoff over hours with a 15 s timeout); nothing current | `Clicksend::Webhook` parses into `SMS::Receipt` / `SMS::InboundMessage`; the extra keys stay in `#raw` |
| Webhook authentication | **None in the current docs**: no signature, HMAC or shared secret. Archived help (no longer published) suggested HTTPS, a URL token, checking `user_id`, and an allowlist of six source IPs last updated around 2019 | No verification method; README prescribes a secret URL and confirming via the API, and warns against the stale IP list |
| Request ID | None documented; no spec declares any response header | `Error#request` describes the call instead |

## Ambiguities and inconsistencies

These were found by the contract specs (`bundle exec rake contract`), which pin the exact list.

1. **Receipt `status_code` type.** The schema says integer; the examples send the string `"201"`.
   The gem accepts both. Not live-verified: no receipt was observed live (see below).
2. **Receipt `digits`.** The schema says non-nullable integer; the examples send `null`. Kept in
   `#raw` only, since ClickSend says it applies to voice receipts.
3. **Send-SMS `date`.** The schema says integer; the example is `"1721099039,"`, a string with a
   trailing comma. **Live: an integer Unix timestamp**, so the schema is right and the example is
   wrong. The gem accepts integers and numeric strings. Anything else gives a nil `sent_at`, with
   the original value kept in `#raw`.
4. **Account `balance_commission`.** The schema says string; the example is a number. **Live: a
   string**, so the schema is right and the example is wrong. Not exposed except through `#raw`.
5. **Prices.** `total_price` is a number but `message_price` is a string. The gem exposes both
   as decimal strings.
6. **Inbound timestamp field.** The `inbound_sms` schema names it `timestamp`; the list example
   uses `timestamp_send`. The gem reads either.
7. **`GET /v3/sms/inbound/{original_message_id}`.** The parameter name suggests the ID of *your*
   original message, but the description says it retrieves "a specific inbound SMS". Not wrapped
   until this is verified; use `client.request`.
8. **Inbound mark-read example.** The request example sends `date_before` as a string
   (`"1961900166"`); the schema says integer. The gem sends an integer.
9. **Batch size.** "Up to 1000 messages" appears in a code-sample comment and in the archived 2022
   docs, not in the current schema. Not enforced.
10. **Blocked messages.** `blocked_count` is documented, but not whether blocked messages also
    appear in `messages[]`. **Live: they do** (a `COUNTRY_NOT_ENABLED` message was listed and
    counted in `blocked_count`). `Batch#all_queued?` checks both.
11. **Rate limits.** 429 is documented, but the referenced "Rate Limiting" section doesn't exist
    (nor in the 2022 archive). See the live results below for what the API actually sends. The
    gem honours `Retry-After`, and since 1.1 exposes the other observed headers as
    `Response#rate_limit` / `APIError#rate_limit`, without depending on them.
12. **Error HTTP statuses.** The docs list application codes such as `INVALID_RECIPIENT` and
    `INSUFFICIENT_CREDIT` but not which HTTP status accompanies them. **Live:** on `/sms/send`,
    `INVALID_RECIPIENT` and `COUNTRY_NOT_ENABLED` are per-message statuses inside an HTTP 200, not
    request-level errors. The status for `INSUFFICIENT_CREDIT` is still unverified.
13. **Account payload contains an API key.** ClickSend's example for `GET /v3/account`, and the
    live response, include `_subaccount.api_key`. `Account#raw` replaces that value with
    `"[REDACTED]"`. The escape hatch returns bodies verbatim, so `client.request(:get,
    "/v3/account").body` contains the key and must not be logged.
14. **History example.** The `view-sms-history` example uses `status: 200` instead of `http_code` and
    omits the pagination wrapper the schema declares. **Live: the schema is right** (paginated
    envelope). History `status_code` is documented as a string; live it was `null` for a
    test-number message.
15. **Help links.** The receipt and inbound-URL help links inside `sms.yaml` now redirect to
    unrelated articles.

## Defensive behaviour (not documented for v3)

- A 2xx response whose envelope `http_code` is >= 400 is treated as that error. This was observed
  on the legacy v2 host, where `send.json` answers HTTP 200 with `{"http_code":401,...}`. Such
  errors are **never retried**, whatever the code. Undocumented behaviour gives no basis for
  knowing whether ClickSend processed the request.
- Duplicate keys in a JSON response are not specially handled. With json 2.x, Ruby warns and
  the last value wins. json 3.x rejects them by default, which surfaces as `MalformedResponseError`.

## Live verification (2026-10-05)

The optional live suite ran against a real account using only ClickSend's test number
`+61411111111` and the invalid number `+000`. On the first run the account didn't have
Australia enabled, so no message was queued. A later run, after Australia was enabled, got one
message accepted (see "Accepted send" below). No charge was incurred in either run. Values
below are shapes and types, not data.

| Behaviour | Documentation | Live result |
|---|---|---|
| Invalid recipient, single send | Not stated | HTTP 200, per-message `status: "INVALID_RECIPIENT"`. The message object is minimal: `to`, `body`, `from`, `schedule` (`""`), `message_id`, `custom_string`, `is_shared_system_number`, `status`. No price, parts, date, country or carrier. |
| Invalid recipient in a batch | Not stated | HTTP 200. Listed in `messages[]` with the same minimal shape. Not counted in `blocked_count`. |
| ClickSend's test number on an account without that country enabled | "A success response will be returned" | HTTP 200, per-message `status: "COUNTRY_NOT_ENABLED"`, `message_price: "0.0000"`, `message_parts: 0`, and counted in `blocked_count`. Test numbers are subject to the account's enabled countries. |
| Message ID format | Not stated | 36-character upper-case UUID, assigned even to rejected messages |
| Authentication failure | 401 | HTTP 401 with `{"http_code":401,"response_code":"UNAUTHORIZED","response_msg":"Authorization failed.","data":null}`, identical on GET, POST and PUT |
| Mark-read with `{"date_before": 1}` | Optional cutoff | Accepted (HTTP 200) on both `PUT /sms/receipts-read` and `PUT /sms/inbound-read` |
| Empty list | `last_page` example shows 1 | `total: 0, current_page: 1, last_page: 0`. `Page` treats it as one empty page. |
| Account payload | Documented fields | Matches the documented fields, plus `ai_enabled` (integer), and a populated `_subaccount` that includes `api_key` (now redacted by the gem) |
| Rate-limit headers | No numbers documented | `x-ratelimit-limit: 20`, `x-ratelimit-remaining`, `ratelimit-reset` (seconds) on 200 and 401 responses from `GET /v3/account` |
| 429 | Documented status only | HTTP 429 with `Retry-After` equal to `ratelimit-reset` (20s and 39s observed), `x-ratelimit-remaining: 0`, and body `{"http_code":429,"response_code":"HTTP_TOO_MANY_REQUESTS","response_msg":"Too many attempts.","data":null}`. The gem maps it to `RateLimitError` with `retry_after` set. |
| How the limit is counted | Not documented | Inferred from the counters: authenticated, wrong-key and unauthenticated calls to `GET /v3/account` drew from one shared allowance of 20 per roughly 60s, while calls to other endpoints did not reduce it. So the limit appears to be per endpoint and per source address, not per account. |

### Accepted send (2026-10-05)

One message to ClickSend's free test number `+61411111111`, with Australia enabled for the
account. This was the only send in the run, and retries were off.

| Behaviour | Live result |
|---|---|
| Response | HTTP 200, `response_code: "SUCCESS"`; per-message `status: "SUCCESS"` |
| Counts | `total_count: 1`, `queued_count: 1`, `blocked_count: 0` |
| Accepted message shape | `direction`, `date`, `to`, `body`, `from`, `schedule`, `message_id`, `message_parts`, `message_price`, `from_email` (null), `list_id` (null), `custom_string`, `contact_id` (null), `user_id`, `subaccount_id`, `is_shared_system_number` (`true`), `country`, `carrier`, `status`. These are exactly the documented fields. |
| Message ID | 36-character upper-case UUID |
| `date` | Integer Unix timestamp; `Message#sent_at` parses it |
| `schedule` | Integer, equal to the send time for an immediate (unscheduled) message, so `Message#scheduled_at` is set even when nothing was scheduled |
| Price and parts | `message_parts: 0`, `message_price: "0.0000"` (string). `total_price` came back as the JSON **integer** `0` (the gem exposes it as `"0"`) |
| `custom_string` | Echoed back exactly |
| Cost | Account balance unchanged before and after the send: no charge |
| Delivery receipt | **None observed.** `GET /v3/sms/receipts/{message_id}` answered HTTP 404 `NOT_FOUND` ("Receipt record not found.") at about 15s, 30s, 60s and 120s after the send. The unread receipt list stayed empty, although the account has an enabled `POLL` receipt rule. Free test-number messages did not produce receipts during this two-minute observation window. |

Receipt retrieval and parsing are therefore verified against ClickSend's published examples and
the contract specs only, **not** against a live receipt.

### Read-only checks (2026-10-06)

| Behaviour | Live result |
|---|---|
| `GET /v3/sms/history?q=to:%2B61411111111&date_from=…&order_by=date:asc&limit=100` (`sms.history(to:, date_from:)`) | HTTP 200, paginated envelope. Exactly one row, the accepted test-number message from 2026-10-05, so `q=to:` filters and the encoded `+` works. Row: `direction: "out"`, `status: "Completed"`, `status_code: null`, `status_text: null`, `message_parts: 0`, `message_price: "0.0000"`, `custom_string` a String, `date` an Integer, `schedule` a String. The documented fields, plus `contact_id`, `user_id`, `subaccount_id`, `first_name`, `last_name`, `_api_username` |
| `GET /v3/account` rate-limit headers through `Response#rate_limit` | `limit: 20`, `remaining` and `reset_in` Integers |

### Still unverified

These need a receipt for a real (non-test) message, existing inbound messages, or the public
test accounts:

- [ ] A live receipt: its shape and `status_code` type. The free test number produced none.
- [ ] Inbound timestamp field (`timestamp` or `timestamp_send`); no inbound messages existed
- [ ] HTTP status and `response_code` for the `nocredit`, `notactive` and `banned` test accounts
- [ ] Whether mark-read accepts an empty `{}` body. Deliberately not tested, because it would
      mark every unread item read (documented). The gem sends `{}` when `before:` is omitted; the
      request schema allows it.
- [ ] A real webhook push: its content type, field names and types (inbound `post`, `get` and
      `json`, and a receipt), its headers, and how `null` is encoded. Field names come from the poll
      schemas, archived docs and ClickSend's integrations. `script/webhook_capture.rb` and the
      capture protocol in `research/1.2-webhooks.md` exist for this
- [ ] Whether `GET /v3/sms/receipts/{message_id}` finds a receipt on an account with only URL rules
- [ ] ClickSend's current retry schedule and timeout for pushes
- [ ] How soon a sent message appears in history, and whether `date_from`/`date_to` are inclusive
- [ ] Where and when `THROTTLED` is returned
- [ ] What `PUT /v3/sms/{message_id}/cancel` answers for a second cancel, an already-sent message
      and an unknown ID (protocol in `research/1.2-api-cancel-quote-history.md`)
- [ ] Whether `POST /v3/sms/price` changes anything: balance, history, `THROTTLED`, rate limits
- [ ] Whether history's `q=to:` matches exactly or by substring
- [ ] Rate limits for endpoints other than `GET /v3/account`

## Retry safety: the rules and why

ClickSend's send endpoints accept no idempotency key. A retry is only safe when the gem
knows the first attempt did not reach ClickSend, or that ClickSend did not act on it.

| Failure | How the gem knows | Retried |
|---|---|---|
| 429 | ClickSend documents it as "a request cannot be served due to the application's rate limit". Inferred, not documented: the observed body (`"Too many attempts."`) looks like a throttling layer's response, produced before the request is handled | every method, honouring `Retry-After` up to 30s |
| Connection refused, DNS failure, connect timeout (`Net::OpenTimeout`) | These can only happen before the request is written | every method |
| Read timeout, connection reset, broken pipe, unreachable host mid-request | The request may have been written and processed | idempotent requests only |
| Mark-read **without** a cutoff | "Mark everything read" is evaluated when ClickSend processes it, so a repeat can hide items that arrived in between | never (since 1.1); with a cutoff it is idempotent |
| TLS errors | Usually a handshake failure (not sent), but `OpenSSL::SSL::SSLError` also covers failures after the request was written | idempotent requests only |
| 5xx | ClickSend may have acted before failing | idempotent requests only |
| Error reported only inside a 2xx body | Undocumented | never |

"Idempotent" means `GET`, the mark-read calls that have a cutoff, and marking one inbound message
read. `client.request` assumes only `GET`, because ClickSend uses `POST` and `PUT` for sends,
purchases and credit transfers.

Since 1.1 this rule lives in the connection and cannot be changed by configuration: a custom
`retry_policy` only chooses delays and the retry budget. When a non-idempotent request fails in
a way that may have been processed (a row above marked "idempotent requests only" or "never", or
a 2xx answer the gem cannot read), the error is extended with `Clicksend::AmbiguousRequestError`.

Underneath the gem there are no hidden retries. `Net::HTTP` retries `GET`/`PUT`/`DELETE`
itself unless `max_retries` is 0, and faraday-net_http sets it to 0.
`spec/integration/send_safety_spec.rb` checks all of this with a local server that counts
arrivals.
