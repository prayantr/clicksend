# Contributing

Thanks for helping. This gem is deliberately small, so please open an issue before starting
on a new wrapped endpoint. `client.request` may already cover your case.

## Setup

```sh
bin/setup
bundle exec rake      # specs + Standard (lint)
```

Ruby 3.3+ is required. CI runs the specs on Ruby 3.3, 3.4 and 4.0.

## Guidelines

- **Use ClickSend's published contract.** Base behaviour on the
  [API reference](https://developers.clicksend.com/docs/) and its OpenAPI files. When the
  documentation is ambiguous, record that in `docs/clicksend-api-notes.md` rather than guessing.
- **Fixtures come from ClickSend.** `spec/fixtures/*.json` are generated from ClickSend's examples
  (`ruby script/openapi_fixtures.rb`). Build error and edge-case responses inline in specs.
- **Run the contract specs** whenever you change request building or add an endpoint. They need
  network access but no credentials:
  ```sh
  bundle exec rake contract
  ```
- **Stay warning-free.** The suite fails on any Ruby warning raised from `lib/`.
- **Never retry what could send twice.** Wrapped calls that are safe to repeat must say so with
  `idempotent: true`. Anything that sends, buys or creates must not.

## Live tests (optional)

Live specs call the real API. They are never needed for a pull request.

```sh
CLICKSEND_LIVE=1 CLICKSEND_USERNAME=... CLICKSEND_API_KEY=... bundle exec rspec --tag live
```

They send only to ClickSend's documented test number. Per ClickSend, that number delivers
nothing and is never charged. Never commit credentials: keep them in your environment or in
the repository's GitHub `live` environment secrets.

## Releasing (maintainers)

1. Update `lib/clicksend/version.rb` and `CHANGELOG.md` in a pull request.
2. After merging, run the **Release** workflow manually. It publishes with RubyGems Trusted
   Publishing and tags the release.
