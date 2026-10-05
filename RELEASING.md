# Preparing a release

## First public source preview

The first public source release uses the existing app version **0.3.1**
(build **84**) and tag **herdrcat-v0.3.1**, matching the repository's version
helpers. It is a GitHub prerelease containing source, not a signed app binary.
The existing version does not need a bump just to tag the public baseline.
Its proposed notes are in [RELEASE_NOTES.md](RELEASE_NOTES.md).

## Checklist

- Use the public repository's `main`; do not import private branches or history.
- Merge release changes through a PR with passing **iOS** and **Web** checks.
- Confirm the chosen commit on `main` has passed CI. Review open security alerts.
- Check README build commands, limitations, security-reporting links, and notices.
- Keep dependency notices consistent with committed locks. Document any unresolved
  artwork, provider-term, or redistribution questions in the release notes.
- Confirm `ios/project.yml`, the generated project, and Info.plist agree on version.
- For source previews, describe what was tested and that live SSH UI tests were
  not run by CI. Attach no credentials, captures of private sessions, or unsigned
  binaries presented as installable apps.

Create a **draft prerelease** at the exact tested commit, review it, then publish
when ready. GitHub supplies source archives when the release is published.
Do not tag a moving branch or an unmerged PR commit.

```sh
# Replace TESTED_COMMIT_SHA with the full commit SHA checked above.
gh release create herdrcat-v0.3.1 \
  --target TESTED_COMMIT_SHA --draft --prerelease \
  --title 'Herdcats 0.3.1 — first public source preview' \
  --notes-file RELEASE_NOTES.md
```

## Later versions

Create a branch, then run `./ios/bin/release MAJOR.MINOR.PATCH`. The helper
increments the current build number (or uses a higher commit-derived number),
regenerates the project, and commits the bump. It requires a clean PR branch
and does not create a tag. Push the branch, review the generated files, and
merge through the same checks. Only then prepare a draft at the tested main SHA.

Fresh public history has fewer commits than the old private repository. Preserve
build-number monotonicity rather than deriving it solely from the new history.
For App Store or TestFlight uploads, also check the highest build already uploaded
and choose a higher number. Do not assume this repository knows every uploaded build.

`ios/bin/deploy` now guides branch preparation and optional branch push; it
ends at the PR stage instead of tagging or uploading before CI.

Signed app distribution is a separate task requiring your own Apple credentials
and signing configuration. `ios/bin/beta` uploads to TestFlight; it is not part
of preparing a GitHub source release.

## Local signing for TestFlight

Keep the shared `ios/project.yml` and generated project free of a personal
`DEVELOPMENT_TEAM` setting. XcodeGen overwrites manual project edits during
release preparation. The TestFlight lane reads the team from your environment
and passes it to the archive and IPA export without storing it in the project:

```sh
export DEVELOPMENT_TEAM=YOURTEAMID
./ios/bin/beta
```

Replace `YOURTEAMID` with the 10-character Team ID from your Apple membership.
The Team ID identifies the membership; it is not an authentication credential.
You still need authorized Apple authentication and signing credentials. Keep
API private keys and Apple sessions outside Git. Existing
`APP_STORE_CONNECT_API_KEY_*` environment variables remain supported; without
an API key, fastlane falls back to Apple session authentication.

`./ios/bin/deploy` only prepares a release PR and does not need Apple credentials.
After the PR is merged and CI passes, use `./ios/bin/beta` separately for an
authorized TestFlight upload.
