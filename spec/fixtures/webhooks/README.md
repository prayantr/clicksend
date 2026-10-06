# Webhook replay fixtures

One file per push request. `spec/clicksend/webhook_replay_spec.rb` replays each through Rack's
request parsing (the params an app would see) and `Clicksend::Webhook`, and checks the result
against `manifest.yml`. A fixture that is not in the manifest fails the suite.

| Extension | Replayed as |
|---|---|
| `.form` | POST, `Content-Type: application/x-www-form-urlencoded`, the file is the body |
| `.query` | GET, the file is the query string |
| `.json` | POST, `Content-Type: application/json`, the file is the body |
| `.http` | the raw request as `script/webhook_capture.rb` saves it: request line, headers, blank line, body |

Directories match the `label` in the manifest: `captured/` (real pushes, redacted),
`first_party/`, `archived/`, `documented/` and `synthetic/`. Only `captured/` is evidence of what
ClickSend sends today; the others record what ClickSend has published, and every value in them is
made up. See `research/1.2-webhooks.md` for the sources.

Rules, enforced by the spec:
- the only phone numbers are ClickSend's documented test numbers;
- request lines use the `/clicksend/:secret/...` placeholder and carry no token;
- headers other than `Content-Type`, `Content-Length`, `User-Agent`, `Accept`, `Accept-Encoding`
  and `Connection` keep their name only (value `[redacted]`).

To add a real push, follow the capture protocol in `research/1.2-webhooks.md`: capture with
`ruby script/webhook_capture.rb serve`, redact with `ruby script/webhook_capture.rb redact`, read
the redacted file yourself, then add it to `captured/` and the manifest.
