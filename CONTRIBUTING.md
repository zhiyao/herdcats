# Contributing to Herdcats

Herdcats is an early-stage iPhone client for Herdr. Contributions to the app,
website, tests, and documentation are welcome. Be respectful, keep feedback
specific, and discuss the work rather than the person.
Participation follows our [code of conduct](CODE_OF_CONDUCT.md).

## Report bugs and propose changes

Search [existing issues](https://github.com/zhiyao/herdcats/issues) before
opening a bug report or feature request. Use the issue forms to describe the
problem, expected behavior, and relevant versions. Discuss substantial features
or architectural changes in an issue before implementing them.

For security vulnerabilities, use the private reporting process in
[SECURITY.md](SECURITY.md). Public issues and PRs must not contain credentials,
private keys, OAuth codes, private pane output, or personal machine details.
Redact screenshots and logs before sharing them.

## Set up your checkout

Fork the repository, clone your fork, and create a branch for your change.
See [README.md](README.md) for build prerequisites, simulator commands, and
connection setup. The app targets iOS 17 or later and requires Xcode 26 or later
to build. The website uses Node.js 22 or later.

Project configuration lives in `ios/project.yml`. After changing targets,
dependencies, build settings, or generated Info.plist properties, regenerate:

```sh
(cd ios && xcodegen generate)
```

For a Dependabot Swift update, reflect the proposed dependency versions in
`ios/project.yml` and commit the regenerated project and lockfile. Generated
project edits alone are overwritten by XcodeGen.

When dependency lockfiles change, refresh the notices using the commands in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md#refresh-the-notices) and review
the resulting license and attribution changes before merging.

## Keep changes focused

- Use Herdr's concepts: spaces, tabs, panes, agents, and machines.
- Keep SSH plus the remote `herdr` CLI as the integration surface. Prefer small
  changes that need no extra daemon or custom transport.
- Follow existing Swift naming and four-space indentation. Keep UI state on the
  main actor and SSH work in `HerdrConnection`.
- Preserve cancellation, command timeouts, and guards against stale connections.
- Keep secrets in Keychain and host-key verification fail closed. Never log
  credentials or weaken host-key approval to make a test pass.
- Quote remote shell arguments in the networking layer. Cover parsing,
  ordering, command construction, and connection changes with regression tests.
- Keep local app state, credentials, generated captures, and private planning
  documents out of commits. Update public setup docs when behavior changes.

## Validate your change

Use the commands in [README.md](README.md#tests-and-github-actions):

- **App changes:** build for the simulator and run the relevant Swift unit
  tests. The attachment-storage check is also part of iOS CI.
- **Website changes:** run `npm ci`, `node --test test/server.test.js`, and
  `npm run build` from `web/`.
- **Documentation changes:** check links, commands, and formatting; an app build
  is not needed for local validation.

Live SSH UI tests require a disposable server and Herdr session; some tests
send input to panes. Keep the locally generated test key outside the checkout.
Never run input tests against a session containing real work.

## Open a pull request

Target `main` and use the PR template to describe the problem, resulting
behavior, validation, and any limitations. Include redacted screenshots when
they help explain UI changes. State which checks you could not run and why.

Both **iOS** and **Web** GitHub Actions checks must pass, and the branch must be
up to date with `main` before merging. A maintainer handles the merge; CI does
not require access to your SSH machine or Apple account credentials.

Contributions are accepted under the repository's [LICENSE](LICENSE), including
its additional distribution permission. Add required attribution for any
third-party code or assets you introduce.
