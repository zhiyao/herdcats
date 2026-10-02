# Herdcats

[![CI](https://github.com/zhiyao/herdcats/actions/workflows/ci.yml/badge.svg)](https://github.com/zhiyao/herdcats/actions/workflows/ci.yml)

A native iPhone client for [Herdr](https://herdr.dev). Connect over SSH to
browse spaces and agents, read pane output, and send terminal input, composed
messages, dictation, and photos from your phone.

Herdcats uses SwiftUI and Observation on iOS 17 or later. It runs the remote
`herdr` CLI over SSH; it needs no companion daemon or custom relay.
[Tailscale](https://tailscale.com) is the recommended way to connect your phone
and Herdr machine. Any network that can reach the SSH server also works.

This is an early release. See the limitations below before using it.

## Build the iPhone app

You need a Mac with Xcode 26 or later, an installed iOS Simulator runtime, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Citadel, the SSH dependency,
is pinned to 0.12.1 and resolves through Swift Package Manager.

```sh
git clone https://github.com/zhiyao/herdcats.git
cd herdcats
brew install xcodegen
(cd ios && xcodegen generate)
open ios/Herdcats.xcodeproj
```

Select the **Herdcats** scheme and an iPhone simulator, then run. To build from
the repository root without opening Xcode:

```sh
xcodebuild -project ios/Herdcats.xcodeproj -scheme Herdcats \
  -destination 'generic/platform=iOS Simulator' build
```

For a physical iPhone, select your own development team in Xcode's Signing &
Capabilities after generation. `ios/project.yml` is the source of truth;
regeneration replaces manual project settings. For command-line device builds,
pass your own team using `DEVELOPMENT_TEAM=YOUR_TEAM_ID`.

## Connect to Herdr

1. Install Herdr on your remote machine and start its default session.
2. Enable SSH access. On macOS, enable **System Settings → General → Sharing →
   Remote Login**. Confirm that SSH works with your account.
3. Connect the phone and machine to the same Tailscale network, or use another
   network where the phone can reach the SSH server.
4. Enter the host, port, username, and password or an **unencrypted OpenSSH
   ed25519 private key** in Herdcats.
5. Compare the host-key fingerprint shown by the app with the server's
   fingerprint through a trusted channel, then approve it.

Remembered credentials and approved host keys stay in the iOS Keychain. A
changed host key blocks connection, including automatic reconnects.

Optional: install [quota-axi](https://www.npmjs.com/package/quota-axi) on the
connected machine to show provider quota. It is not required for pane access.

## Tests and GitHub Actions

[GitHub Actions](https://github.com/zhiyao/herdcats/actions) runs on pushes to
`main`, pull requests, and manual dispatch:

- **iOS:** generate the Xcode project, check attachment-storage behavior, build
  the app, and run Swift unit tests on an available iPhone simulator.
- **Web:** install locked dependencies, run server regression tests, and build
  the static website.

These checks require no SSH server, Apple account credentials, or deployment
secrets. Simulator tests use ad-hoc signing so Keychain tests receive their
entitlements.

Run the same checks locally from the repository root:

```sh
python3 ios/HerdcatsTests/test_attachment_storage.py
xcodebuild -project ios/Herdcats.xcodeproj -scheme Herdcats -showdestinations

# Replace SIMULATOR_UDID with an available iPhone simulator ID.
xcodebuild -project ios/Herdcats.xcodeproj -scheme Herdcats \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  test -only-testing:HerdcatsTests \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
```

Live SSH UI tests are separate from CI. Some send input to panes: use a
**disposable SSH server and Herdr session**, with a locally generated key kept
outside Git. Configure `TEST_RUNNER_HC_USER`, `TEST_RUNNER_HC_PORT`, and
`TEST_RUNNER_HC_KEY_PATH`; live connection tests skip when the key path is absent.

## Website

The `web/` directory contains the Next.js landing page. Use Node.js 22 or later:

```sh
cd web
npm ci
node --test test/server.test.js
npm run build
npm run dev
```

The production build exports static files to `web/out/`. The website can be
hosted independently of the iPhone app.

## Current limitations

- SSH authentication supports passwords and unencrypted OpenSSH ed25519 keys.
  Encrypted keys and other private-key formats are not supported.
- A readable Herdr default session is required; session selection is not wired up.
- Backgrounding pauses polling. This is not a general-purpose SSH shell.
- There is no in-app host-key rotation flow. A changed key fails closed.
- Uploaded photos remain under `~/.cache/herdrcat/attachments` on the connected
  machine until you remove them; the app does not automatically delete them.
- Saved-machine routing uses the gateway machine's SSH configuration. Quota and
  photos are available only on the directly connected host.

## Security

Report vulnerabilities through [GitHub's private reporting form](https://github.com/zhiyao/herdcats/security/advisories/new).
See [SECURITY.md](SECURITY.md) for supported versions and reporting guidance.

## License

[GPLv3 with an additional permission for Apple App Store and Google Play
 distribution](LICENSE). Internal planning documents, local configuration,
credentials, and generated review artifacts are excluded from this repository.
