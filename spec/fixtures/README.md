# Fixtures

These JSON files are ClickSend's own response examples, taken from the OpenAPI
files published at `https://developers.clicksend.com/docs/_spec/<section>.yaml`.
They are generated, not hand-written:

```sh
bundle exec rake contract:fetch      # download the OpenAPI files into tmp/openapi
ruby script/openapi_fixtures.rb      # regenerate this directory
```

| Fixture | Operation | Source |
|---|---|---|
| `account.json` | `GET /v3/account` | assembled from per-property examples |
| `sms_send.json` | `POST /v3/sms/send` | assembled from per-property examples |
| `sms_receipts.json` | `GET /v3/sms/receipts` | verbatim example |
| `sms_receipt.json` | `GET /v3/sms/receipts/{message_id}` | verbatim example |
| `sms_receipts_read.json` | `PUT /v3/sms/receipts-read` | assembled from per-property examples |
| `sms_inbound.json` | `GET /v3/sms/inbound` | verbatim example |
| `sms_inbound_read.json` | `PUT /v3/sms/inbound-read` | assembled from per-property examples |
| `sms_inbound_message_read.json` | `PUT /v3/sms/inbound-read/{message_id}` | verbatim example |

They are kept exactly as published, including places where ClickSend's examples
disagree with its schemas (listed in `spec/contract/openapi_contract_spec.rb`).
Error and partial-failure responses, which ClickSend does not publish examples
for, are built inline in the specs that use them.

`bundle exec rake contract` fails if ClickSend changes an example these files
were generated from.

## Webhook (push) fixtures

`webhook_receipt.json` and `webhook_inbound.json` are **hand-written**, not generated and not
captured from a live push. ClickSend's current documentation defines no push payload. The field
lists come from the archived REST v3 docs ("Push Delivery Receipts" and "Push Inbound SMS",
Wayback snapshot of 2022-05-02), and agree with the current poll schemas (`sms_receipt`,
`inbound_sms`) apart from `status` and `user_id` (and `subaccount_id` on inbound), which only the
archived docs list. Every value is a String, as a form-encoded POST arrives in Rack. The empty
`error_code`/`error_text` assume a null is sent as an empty field (undocumented). Phone numbers
are ClickSend test numbers and the IDs are made up. `spec/contract/webhook_contract_spec.rb`
checks the field names against ClickSend's current schemas.
