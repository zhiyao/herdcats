# Unreleased

- Support passphrase-protected OpenSSH ed25519 keys using AES-128-CTR or
  AES-256-CTR with bcrypt at 1–256 rounds. Optional device-only passphrase
  storage enables reconnects after relaunch.
- Citadel 0.12.1 is vendored with fixes for its bcrypt round limit and OpenSSH padding.
- Reduce Live pane latency by reusing separate persistent SSH shell channels for
  input and output reads, with ordered acknowledgements and no replay of uncertain
  sends ([#24](https://github.com/zhiyao/herdcats/pull/24)).
- Keep the screen awake during voice dictation and restore Auto-Lock afterward
  ([#25](https://github.com/zhiyao/herdcats/pull/25)).
- Let users replace changed SSH host keys after verifying both fingerprints and
  explicitly approving the replacement ([#29](https://github.com/zhiyao/herdcats/pull/29)).
- Add Moonlit App Store screenshot artwork, a 6.3-inch iPhone target, and header
  and search creative assets ([#30](https://github.com/zhiyao/herdcats/pull/30)).
- Add Open Graph and X large-image preview metadata and `og.png`
  ([#31](https://github.com/zhiyao/herdcats/pull/31)).
- Link the SSH Setup Guide directly to the support connection instructions
  ([#32](https://github.com/zhiyao/herdcats/pull/32)).
- Align website copy with app behavior, add support contact details, and publish
  robots.txt and a sitemap ([#33](https://github.com/zhiyao/herdcats/pull/33)).

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
