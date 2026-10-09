# Third-party notices

Reviewed against the committed dependency locks on 2026-10-04. Herdcats' own
code is covered by [LICENSE](LICENSE). Dependency licenses and notices remain
in force; the project's App Store distribution permission does not extend to
third-party copyright holders.

## iPhone app

Full project and dependency license texts are bundled in
[ios/Herdcats/Resources/ThirdPartyNotices.txt](ios/Herdcats/Resources/ThirdPartyNotices.txt)
and available offline in **Settings → Licenses**. The notices preserve upstream
NOTICE files, runtime-library exceptions, and the embedded BoringSSL license.

| Dependency | Locked version | License |
| --- | --- | --- |
| BigInt | 5.7.0 | MIT |
| Citadel (vendored, patched) | 0.12.1 | MIT |
| Swift ASN.1 | 1.7.3 | Apache-2.0 |
| Swift Atomics | 1.3.1 | Apache-2.0 with Swift Runtime Library Exception |
| Swift Collections | 1.7.1 | Apache-2.0 with Swift Runtime Library Exception |
| Swift Crypto | 3.15.1 | Apache-2.0; embedded component terms also apply |
| Swift Log | 1.15.1 | Apache-2.0 |
| Swift NIO | 2.103.0 | Apache-2.0; embedded component terms also apply |
| Swift NIO SSH (Wellz26 fork) | 0.3.7 | Apache-2.0 |
| Swift System | 1.8.1 | Apache-2.0 with Swift Runtime Library Exception |
| Jost font (unmodified variable TTF) | google/fonts `5e8a3ba` | SIL OFL 1.1 |
| Silkscreen font (Regular, Bold) | google/fonts `5e8a3ba` | SIL OFL 1.1 |

The precise source revisions and license-file URLs are recorded in
[licenses/dependency-inventory.json](licenses/dependency-inventory.json).
The generator also includes BoringSSL at the revision identified by Swift
Crypto's vendoring record and NIO's embedded llhttp license. No Swift package
source was modified by that license review. Citadel is now vendored with a bounded bcrypt-round
patch; see [patch notes](ios/ThirdParty/Citadel/HERDCATS-PATCH.txt).

The reviewed MIT and Apache-2.0 terms do not identify a conflict with the
project's GPLv3 licensing. See [Apache's GPL compatibility guidance](https://apache.org/licenses/GPL-compatibility.html).
Keep the original notices when redistributing builds or dependency source.

## Website

Next.js, React, React DOM, Scheduler, and styled-jsx use MIT; SWC Helpers uses
Apache-2.0. The browser-framework notices, including license files embedded in
Next.js, are preserved in [web/public/third-party-notices.txt](web/public/third-party-notices.txt).
The static export includes this file and the site's legal navigation links to it.
The full npm lockfile inventory also records optional platform packages and
build/deployment dependencies that are not shipped as browser code.

Both the website and the iPhone app ship the Jost and Silkscreen fonts under
the SIL Open Font License 1.1, pinned to the same google/fonts revision. The
website self-hosts them through `next/font`, and the app bundles the unmodified
files in `ios/Herdcats/Resources/Fonts`. Their OFL texts are included in both
notice files, and their revisions and license URLs are recorded in the
dependency inventory. The app's terminal output still uses the system
monospaced font, and the app uses Apple's system symbols through platform APIs.

## Screenshot and release tools

These tools are installed separately and are not linked into the iPhone app
or shipped with the static website:

- **Remotion 4.0.523:** the screenshot renderer uses Remotion's custom license.
  The pinned [license](https://github.com/remotion-dev/remotion/blob/v4.0.523/LICENSE.md)
  permits image/video creation for eligible individuals, for-profit organizations
  with up to three employees, nonprofits, and noncommercial evaluation. Other
  organizations need a Company License. Its restrictions on relicensing
  Remotion itself still apply. The GPL license here does not relicense Remotion.
- **Fastlane and gems:** all 102 locked gems have registry license metadata or
  a license recovered from their exact released archive. Babosa 1.0.4 and
  Colored 1.2 have MIT licenses in their archives despite missing registry
  metadata. The inventory preserves those texts. Gems with multiple license
  identifiers require reading their upstream terms; metadata arrays are not
  automatically an SPDX `OR` expression.
- **Other tooling components:** npm dependencies include LGPL-licensed libvips
  binaries and MPL-2.0 media tooling. Fastlane's gem set also includes Ruby,
  BSD, LGPL, EPL, and GPL license identifiers. Their terms matter if those tools,
  binaries, or modified sources are redistributed. This review does not bundle
  or relicense them as Herdcats code.

## Artwork provenance

The maintainer confirmed on 2026-10-04 that the cat/logo artwork, six agent icons,
app/launch images, and three website prototype JPGs were AI-generated. Original
generation-provider terms and prompt histories were not recorded for those assets.
This is an origin statement, not a claim that trademark or other third-party
rights have been cleared. Agent names and brand-like icons identify supported
software; inclusion does not imply endorsement or transfer trademark rights.

On 2026-10-04, the app icon and app/website logos were replaced with a three-cat
pixel design generated with OpenAI's built-in image-generation tool and chosen
by the maintainer. The standard agent logos are retained. Generation details for
the new herd artwork are recorded in `licenses/artwork-provenance.json`.
On 2026-10-09, the app icon and app/website logos were replaced with the
single pixel cat from the launch screen on the dark night canvas. The new art is
rendered by `ios/scripts/generate_logo.py` from the project's own launch-cat
blocks and uses no generated imagery. Future externally sourced assets need
their source and license recorded here.

## Refresh the notices

After changing dependency locks, install the website's locked packages, then run:

```sh
(cd web && npm ci)
python3 scripts/update-license-notices.py
(cd ios && xcodegen generate)
```

The script reads the exact Swift revisions from GitHub, exact gem metadata and
released license files from RubyGems, and browser-package licenses from the
installed npm versions. It refuses version mismatches and missing required
license files. Review its output before committing. The inventory records
metadata as reported upstream; it is not a replacement for the license texts.

For a binary release, retain the bundled notices, publish the corresponding
Herdcats source and build instructions required by GPLv3, and recheck terms for
any tools or dependency binaries included in that release.
