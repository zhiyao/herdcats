# Herdcats 0.3.1 — first public source preview

This is the first release from the fresh public repository. It is a source
preview for people who want to build the app themselves; no signed iPhone
binary or App Store submission is included.

## Included

- Native iPhone client for Herdr, using SSH with Tailscale as the recommended network.
- Navigation for spaces, agents, tabs, panes, and machines.
- Terminal output and Live, Compose, and Voice input, plus photo attachments.
- Password or unencrypted OpenSSH ed25519 authentication, explicit host-key
  approval, pinned host keys, and Keychain credential storage.
- Optional quota-axi integration and an independent static Next.js website.
- Build instructions, GitHub CI, dependency updates, private vulnerability
  reporting, contribution templates, and community standards.
- Offline license notices in Settings and on the welcome screen, with website
  notices and a dependency inventory.

## Build and connect

The app targets iOS 17 or later. Building requires a Mac, Xcode 26 or later,
and XcodeGen. Use your own signing team for a physical iPhone. The website
uses Node.js 22 or later. Follow [README.md](https://github.com/zhiyao/herdcats/blob/main/README.md)
for commands and SSH/Herdr setup.

## Known limitations

- Requires a readable Herdr default session; session selection is not wired up.
- Encrypted SSH keys and private-key formats other than OpenSSH ed25519 are unsupported.
- Backgrounding pauses polling. Host-key changes fail closed; there is no
  in-app rotation flow.
- Photos remain in `~/.cache/herdrcat/attachments` on the connected host until
  removed manually. Quota and photos work only on the directly connected host.
- Live SSH UI tests are outside CI and require a disposable test session.

## Licensing and security

Herdcats uses GPLv3 with an additional store-distribution permission. Third-party
terms remain applicable. The optional Remotion screenshot tool has its own
eligibility conditions. AI-artwork provenance is recorded; provider terms and
trademark clearance are not established by that statement. See
[third-party notices](https://github.com/zhiyao/herdcats/blob/main/THIRD_PARTY_NOTICES.md).

Report vulnerabilities [privately](https://github.com/zhiyao/herdcats/security/advisories/new).
