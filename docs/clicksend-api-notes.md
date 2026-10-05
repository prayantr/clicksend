# ClickSend API notes

How this gem interprets ClickSend's REST v3 documentation, where that documentation is
ambiguous, and what still needs checking against the live API. Last reviewed 2026-10-05.

Sources:
- [API reference](https://developers.clicksend.com/docs/), with its OpenAPI files at
  `https://developers.clicksend.com/docs/_spec/<section>.yaml`
- [Testing](https://developers.clicksend.com/docs/testing)
- [SMS error codes](https://help.clicksend.com/en/articles/42318-sms-error-codes)

## Behaviour taken from the documentation

| Topic | Documented behaviour | Gem behaviour |
|---|---|---|
| Base URL and auth | `https://rest.clicksend.com/v3`, HTTP Basic with username and API key | Same |
| Envelope | `{http_code, response_code, response_msg, data}` | Parsed into `Response`; `response_code`/`response_msg` exposed on errors |
| HTTP statuses | 200, 201, 204, 400, 401, 403, 404, 405, 429, 500 | Mapped to the error hierarchy |
| Per-message status | `/sms/send` `http_code` "doesn't reflect the status of each message" | `MessageRejected` (single) / `Batch#rejected` |
| Pagination | `page` (default 1) and `limit` (default 15, min 15, max 100); `total`, `per_page`, `current_page`, `last_page` | `Page`; `limit` checked against 15..100 |
| Receipt status codes | 200 sent/queued, 201 delivered, 300 temporary failure (ClickSend retries), 301 failed | `pending?` / `delivered?` / `failed?` |
| Unread-only lists | Receipts and inbound marked read "won't be shown" in the list endpoints | Documented in the README (paging pitfall) |
| POLL rules | Polling receipts and inbound requires a rule with the POLL action | Documented |
| Mark-read cutoff | `date_before`, Unix timestamp, optional | `before:` (Time or Integer); `{}` when omitted, which matches the request schema |
| Unicode | Detected automatically; no `messagetype` in v3 | Not exposed |
| URLs in SMS | Paused for new customers pending approval | Documented |
| Test numbers | e.g. `+61411111111`: "No messages will be sent, and your account won't be charged" | Used by the live specs |
| Idempotency | No idempotency key on any send operation | Sends are never retried after timeouts or 5xx |

## Ambiguities and inconsistencies

These were found by the contract specs (`bundle exec rake contract`), which pin the exact list.

1. **Receipt `status_code` type.** The schema says integer; the examples send the string `"201"`.
   The gem accepts both.
2. **Receipt `digits`.** The schema says non-nullable integer; the examples send `null`. Kept in
   `#raw` only, since ClickSend says it applies to voice receipts.
3. **Send-SMS `date`.** The schema says integer; the example is `"1721099039,"`, a string with a
   trailing comma. The gem accepts integers and numeric strings. Anything else gives a nil
   `sent_at`, with the original value kept in `#raw`.
4. **Account `balance_commission`.** The schema says string; the example is a number. Not exposed
   except through `#raw`.
5. **Prices.** `total_price` is a number but `message_price` is a string. The gem exposes both
   as decimal strings.
6. **Inbound timestamp field.** The `inbound_sms` schema names it `timestamp`; the list example
   uses `timestamp_send`. The gem reads either.
7. **`GET /v3/sms/inbound/{original_message_id}`.** The parameter name suggests the ID of *your*
   original message, but the description says it retrieves "a specific inbound SMS". Not wrapped
   until this is verified; use `client.request`.
8. **Inbound mark-read example.** The request example sends `date_before` as a string
   (`"1961900166"`); the schema says integer. The gem sends an integer.
9. **Batch size.** "Up to 1000 messages" appears only in a code-sample comment, not in the schema.
   Not enforced.
10. **Blocked messages.** `blocked_count` is documented, but not whether blocked messages also
    appear in `messages[]`. `Batch#all_queued?` checks both.
11. **Rate limits.** 429 is documented, but the referenced "Rate Limiting" section doesn't exist.
    Unauthenticated responses carry `x-ratelimit-limit`/`x-ratelimit-remaining`/`retry-after`
    (observed). The gem honours `Retry-After` and doesn't depend on the other headers.
12. **Error HTTP statuses.** The docs list application codes such as `INVALID_RECIPIENT` and
    `INSUFFICIENT_CREDIT` but not which HTTP status accompanies them on single-resource calls.
    The gem maps by HTTP status and exposes `response_code` either way.

## Defensive behaviour (not documented for v3)

- A 2xx response whose envelope `http_code` is >= 400 is treated as that error. This was observed
  on the legacy v2 host, where `send.json` answers HTTP 200 with `{"http_code":401,...}`.
- Duplicate keys in a JSON response are not specially handled. With json 2.x, Ruby warns and
  the last value wins. json 3.x rejects them by default, which surfaces as `MalformedResponseError`.

## Needs live verification

Run the optional live specs (see CONTRIBUTING.md) to settle these:

- [ ] How an invalid recipient is reported for `/sms/send`: HTTP 200 with a per-message status,
      or a 4xx for the whole request?
- [ ] HTTP status and `response_code` for an account without credit (ClickSend's public
      `nocredit` test account) and for inactive or banned accounts
- [ ] Rate-limit headers and limits for authenticated requests
- [ ] Whether `PUT /sms/receipts-read` and `/sms/inbound-read` accept an empty JSON object
- [ ] Inbound timestamp field name in real responses (`timestamp` or `timestamp_send`)
- [ ] Whether `message_id` values are always UUID-like. The gem accepts `[A-Za-z0-9-]+` in paths.
