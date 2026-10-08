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

The current project state, settled decisions and known limitations are in [`HANDOFF.md`](HANDOFF.md).

Releases are published to RubyGems by the **Release** workflow using Trusted Publishing (OIDC).
No RubyGems API key is stored anywhere.

1. In a pull request, bump `lib/clicksend/version.rb`, refresh `Gemfile.lock` and
   `companions/clicksend-opentelemetry/Gemfile.lock` (`bundle lock` in each directory; a spec
   fails if either still records the old version), and date the `CHANGELOG.md` entry. Merge it
   into `master` once CI and Contract are green.
2. Create an annotated tag on that `master` commit:
   ```sh
   git tag -a vX.Y.Z -m "clicksend X.Y.Z" <master-commit-sha>
   ```
3. Push only that tag:
   ```sh
   git push origin refs/tags/vX.Y.Z
   ```
4. Run the Release workflow **from the tag**. In the Actions UI, choose "Use workflow from →
   Tags → vX.Y.Z", or run:
   ```sh
   gh workflow run release.yml --ref vX.Y.Z
   ```
   The `rubygems` environment only accepts runs from `v*` tags.
5. The workflow runs the specs, builds the gem and publishes it to RubyGems through Trusted
   Publishing.
6. The workflow does not create or push the tag. Bundler's `rake release` finds the existing
   tag and skips tagging.

`master` only changes through pull requests, and the CI checks must pass first. Release tags
(`v*` and `clicksend-opentelemetry-v*`) can be created but never moved or deleted, so a tag on
the wrong commit means releasing a new version, not retagging.

### clicksend-opentelemetry

The companion gem in `companions/clicksend-opentelemetry` is released the same way, on its own
version line, by the **Release clicksend-opentelemetry** workflow and the
`rubygems-clicksend-opentelemetry` environment, which only accepts runs from
`clicksend-opentelemetry-v*` tags:

1. In a pull request, bump `companions/clicksend-opentelemetry/lib/clicksend/opentelemetry/version.rb`,
   refresh its `Gemfile.lock`, and date its `CHANGELOG.md` entry. Merge it once CI is green.
2. Tag that `master` commit and push only the tag:
   ```sh
   git tag -a clicksend-opentelemetry-vX.Y.Z -m "clicksend-opentelemetry X.Y.Z" <master-commit-sha>
   git push origin refs/tags/clicksend-opentelemetry-vX.Y.Z
   ```
3. Run the workflow from the tag:
   ```sh
   gh workflow run release-clicksend-opentelemetry.yml --ref clicksend-opentelemetry-vX.Y.Z
   ```

Its GitHub release should not be marked "latest", which belongs to `clicksend`.
