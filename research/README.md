# Research (historical)

These documents are the research behind 1.2.0, written on 2026-10-06 against the frozen 1.1.0
release. They are kept as a record of the evidence and the decisions it supported. **They are not
current documentation**: where they disagree with the code, `README.md`, `CHANGELOG.md` or
`docs/clicksend-api-notes.md`, those win. The project's current state and settled decisions are in
[`HANDOFF.md`](../HANDOFF.md).

| Document | What it covers | Outcome |
|---|---|---|
| [`1.2-architecture-proposal.md`](1.2-architecture-proposal.md) | Synthesis of the 1.2 tracks: keep, change, add, reject; core vs optional gems; release plan | Mostly shipped in 1.2.0; its "Reject" list stands (see `HANDOFF.md`) |
| [`1.2-api-cancel-quote-history.md`](1.2-api-cancel-quote-history.md) | `sms.cancel`, `sms.quote`, history search; the B3.7 live cancel protocol and its 2026-10-06 result | Cancel shipped as experimental; quote deferred |
| [`1.2-webhooks.md`](1.2-webhooks.md) | Webhook evidence, replay fixtures, capture protocol | Fixtures and `script/webhook_capture.rb` shipped; webhooks stay experimental |
| [`1.2-observability-and-http.md`](1.2-observability-and-http.md) | OpenTelemetry companion design; persistent-connection semantics and benchmarks | Companion released as 0.1.0; persistent connections opt-in |
| [`1.2-ruby-ecosystem-proposal.md`](1.2-ruby-ecosystem-proposal.md) | Rails, ActiveJob, Sidekiq, testing and observability integration | README job and observability guidance; no Rails gem |

The throwaway experiment code these documents cite (ActiveJob and Sidekiq experiments,
persistent-connection benchmarks) is not on `master`. It is preserved, unchanged, at two tags:

- `archive/research-ecosystem` (`research/experiments/`): the ActiveJob, Sidekiq, in-flight
  marker, observability and test-helper experiments.
- `archive/spike-1.2-observability-http` (`bench/`): the persistent-connection specs, the
  keep-alive server and the HTTP and OpenTelemetry benchmarks.

Branch and commit names inside these documents (`spike/1.2-*`, `research/ecosystem`,
`hardening/1.1`, `next/1.1`) refer to branches that no longer exist; their work is on `master`
or at the tags above.
