# Security policy

## Supported versions

Security fixes target the current `main` branch of this repository. Older
commits and forks do not have a separate security maintenance policy. If you
find an issue in an older build, include its version or commit in your report.

## Report a vulnerability

Use [GitHub's private vulnerability reporting form](https://github.com/zhiyao/herdcats/security/advisories/new).
You can also open the repository's **Security → Advisories → Report a vulnerability**
page. A GitHub account is required to submit a report.

Please report suspected vulnerabilities privately rather than opening a
public issue or pull request with exploit details.

Include:

- The affected version or commit and relevant iOS, Xcode, or remote CLI versions.
- A description of the vulnerability and its potential impact.
- Reproduction steps using a disposable test machine or session when possible.
- A minimal proof of concept and any relevant, redacted logs or screenshots.

Do not include real passwords, private keys, OAuth codes, API tokens, or
unrelated private pane output. If a credential was exposed, revoke or rotate
it before sharing reproduction material.

The maintainers will review the report and use the private advisory to discuss
reproduction, fixes, and coordinated public disclosure with you.

## Scope

This policy covers Herdcats' iOS app, website, and repository tooling. Relevant
issues include SSH host-key verification, credential and local-data storage,
remote command construction, pane-input routing, attachment handling, and
sign-in flows.

For a vulnerability confined to Herdr, Citadel, or another upstream dependency,
use that project's reporting process. If it also affects Herdcats, report the
Herdcats impact here without publishing the upstream exploit details.
