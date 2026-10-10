#!/usr/bin/env python3
"""Refresh pinned dependency inventories and shipped notices using public sources.

Requires `npm ci` in web/. Run from the repository root with Python 3.11+.
No dependencies are upgraded. Downloads are reads of public license/metadata URLs.
"""
import concurrent.futures
import json
import io
from pathlib import Path
import re
import tarfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Herdcats-license-review"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8")


def write(path, text):
    target = ROOT / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding="utf-8")


def section(title, source, text):
    return f"\n{'=' * 72}\n{title}\nSource: {source}\n{'=' * 72}\n\n{text.rstrip()}\n"


def swift_notices():
    pins = json.loads((ROOT / "ios/Herdcats.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())["pins"]
    # Local Citadel no longer appears in Package.resolved; preserve its upstream notices.
    pins.append({"identity": "citadel", "location": "https://github.com/orlandos-nl/Citadel",
                 "state": {"version": "0.12.1", "revision": "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"}})
    pins.sort(key=lambda pin: pin["identity"])
    inventory, notices = [], ["Herdcats and third-party software licenses\n\n"]
    notices.append(section("Herdcats", "https://github.com/zhiyao/herdcats/blob/main/LICENSE", (ROOT / "LICENSE").read_text()))
    for pin in pins:
        repo = pin["location"].removeprefix("https://github.com/").removesuffix(".git")
        rev = pin["state"]["revision"]
        tree = json.loads(fetch(f"https://api.github.com/repos/{repo}/git/trees/{rev}?recursive=1"))
        if tree.get("truncated"):
            raise ValueError(f"Incomplete tree for {repo}")
        paths = sorted(entry["path"] for entry in tree["tree"] if entry["type"] == "blob" and re.match(r"^(license|notice|copying|copyright)(\.|$)", Path(entry["path"]).name, re.I))
        if not any(Path(p).name.lower().startswith("license") for p in paths):
            raise ValueError(f"Missing license for {repo}")
        sources = []
        for path in paths:
            url = f"https://raw.githubusercontent.com/{repo}/{rev}/{path}"
            sources.append(url)
            notices.append(section(f"{pin['identity']} {pin['state']['version']} — {path}", url, fetch(url)))
        inventory.append({"name": pin["identity"], "version": pin["state"]["version"], "revision": rev, "repository": pin["location"], "license_sources": sources})
        if pin["identity"] == "citadel":
            inventory[-1]["vendored_path"] = "ios/ThirdParty/Citadel"
            inventory[-1]["patch_notes"] = "ios/ThirdParty/Citadel/HERDCATS-PATCH.txt"
        if pin["identity"] == "swift-crypto":
            hash_text = fetch(f"https://raw.githubusercontent.com/{repo}/{rev}/Sources/CCryptoBoringSSL/hash.txt")
            boring_rev = re.search(r"revision ([0-9a-f]{40})", hash_text)[1]
            url = f"https://raw.githubusercontent.com/google/boringssl/{boring_rev}/LICENSE"
            notices.append(section(f"BoringSSL {boring_rev} (embedded in Swift Crypto)", url, fetch(url)))
            inventory.append({"name": "BoringSSL", "revision": boring_rev, "embedded_in": "swift-crypto", "license_sources": [url]})
    notices.append(section("Catppuccin palette 1.8.0", "https://github.com/catppuccin/palette",
                           (ROOT / "licenses/catppuccin-MIT.txt").read_text()))
    notices.append(section("Solarized palette", "https://github.com/altercation/solarized",
                           (ROOT / "licenses/solarized-MIT.txt").read_text()))
    notices.extend(font_notices(APP_FONTS))
    return inventory, "".join(notices)


def npm_inventory(lockfile):
    lock = json.loads((ROOT / lockfile).read_text())
    records = []
    for path, package in sorted(lock["packages"].items()):
        if not path:
            continue
        name = path.rsplit("node_modules/", 1)[1]
        record = {"name": name, "version": package["version"], "license": package.get("license"), "development_only": package.get("dev", False), "optional": package.get("optional", False)}
        if not record["license"]:
            if name.startswith("@remotion/"):
                record["license_source"] = f"https://github.com/remotion-dev/remotion/blob/v{package['version']}/LICENSE.md"
                record["review_note"] = "No license field in lockfile; consult pinned upstream Remotion license."
            else:
                record["review_note"] = "License metadata missing; manual review required."
        records.append(record)
    return records


CODE_SUFFIXES = {".js", ".mjs", ".cjs", ".map", ".ts"}

# Fonts loaded with next/font/google in web/app/layout.tsx, pinned to a google/fonts commit.
GOOGLE_FONTS_REVISION = "5e8a3ba899557829a76cfdac30fa512bda91d7ca"
WEB_FONTS = [("Jost", "jost"), ("Silkscreen", "silkscreen")]
# The same font files, unmodified, are bundled in ios/Herdcats/Resources/Fonts.
APP_FONTS = WEB_FONTS
APP_FONT_FILES = {"Jost": ["Jost-Variable.ttf"], "Silkscreen": ["Silkscreen-Regular.ttf", "Silkscreen-Bold.ttf"]}


def font_license_url(folder):
    return f"https://raw.githubusercontent.com/google/fonts/{GOOGLE_FONTS_REVISION}/ofl/{folder}/OFL.txt"


def font_notices(fonts):
    notices = []
    for family, folder in fonts:
        url = font_license_url(folder)
        notices.append(section(f"{family} font — OFL.txt", url, fetch(url)))
    return notices


def font_inventory(fonts, bundled_files=None):
    records = []
    for family, folder in fonts:
        record = {"name": family, "license": "OFL-1.1", "revision": GOOGLE_FONTS_REVISION, "repository": "https://github.com/google/fonts", "upstream_path": f"ofl/{folder}", "license_sources": [font_license_url(folder)]}
        if bundled_files:
            record["bundled_files"] = [f"ios/Herdcats/Resources/Fonts/{name}" for name in bundled_files[family]]
        records.append(record)
    return records


def web_notices():
    lock = json.loads((ROOT / "web/package-lock.json").read_text())
    notices = ["Herdcats website third-party notices\n\nIncludes the browser framework packages and licenses embedded in Next.js.\nBuild and deployment tooling is inventoried separately in licenses/dependency-inventory.json.\n"]
    browser_packages = {"next", "react", "react-dom", "scheduler", "styled-jsx", "@swc/helpers", "lucide-react"}
    notices.append(section("Herdcats", "https://github.com/zhiyao/herdcats/blob/main/LICENSE", (ROOT / "LICENSE").read_text()))
    for path, package in sorted(lock["packages"].items()):
        if not path or path.removeprefix("node_modules/") not in browser_packages:
            continue
        directory = ROOT / "web" / path
        if not directory.exists():
            if not package.get("optional", False):
                raise ValueError(f"Run npm ci in web/: missing {path}")
            continue
        installed = json.loads((directory / "package.json").read_text())
        if installed["version"] != package["version"]:
            raise ValueError(f"Run npm ci in web/: version mismatch for {path}")
        # Skip code files: lucide-react ships an icon module named copyright.mjs.
        files = sorted(p for p in directory.rglob("*") if p.is_file() and "node_modules" not in p.relative_to(directory).parts and p.suffix not in CODE_SUFFIXES and re.match(r"^(license|notice|copying|copyright|thirdpartynotice|thirdpartycopyright)(\.|$)", p.name, re.I))
        if not files:
            raise ValueError(f"Missing installed license files for {path}")
        for file in files:
            relative = file.relative_to(directory)
            text = file.read_text(encoding="utf-8")
            notices.append(section(f"{path.removeprefix('node_modules/')} {package['version']} — {relative}", package.get("resolved", "npm registry"), text))
    # next/font self-hosts these Google Fonts in the built site, so their licenses ship too.
    notices.extend(font_notices(WEB_FONTS))
    return "".join(notices)


def gem_inventory():
    lock = (ROOT / "ios/Gemfile.lock").read_text()
    gems = re.findall(r"^    ([\w.-]+) \(([^ )]+)\)$", lock, re.M)
    def record(pair):
        name, version = pair
        url = f"https://rubygems.org/api/v2/rubygems/{urllib.parse.quote(name)}/versions/{urllib.parse.quote(version)}.json"
        metadata = json.loads(fetch(url))
        result = {"name": name, "version": version, "licenses": metadata.get("licenses") or [], "homepage": metadata.get("homepage_uri"), "metadata_source": url}
        if not result["licenses"]:
            # These locked releases predate registry license metadata. Retain
            # the actual released license text instead of inferring from HEAD.
            gem_url = f"https://rubygems.org/downloads/{name}-{version}.gem"
            with urllib.request.urlopen(gem_url, timeout=60) as response:
                outer = tarfile.open(fileobj=io.BytesIO(response.read()))
            payload = outer.extractfile("data.tar.gz")
            if payload is None:
                raise ValueError(f"Missing gem payload for {name}")
            inner = tarfile.open(fileobj=io.BytesIO(payload.read()), mode="r:gz")
            texts = []
            for member in inner.getmembers():
                if member.isfile() and re.search(r"license|copying", Path(member.name).name, re.I):
                    text = inner.extractfile(member).read().decode("utf-8")
                    texts.append({"file": member.name, "text": text})
            if not texts:
                raise ValueError(f"Manual license review needed for {name}")
            result["released_license_files"] = texts
            result["released_license_source"] = gem_url
        return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        return sorted(pool.map(record, gems), key=lambda item: item["name"])


def main():
    # Finish collection before writing, so a failed download doesn't leave partial output.
    swift, ios_text = swift_notices()
    web_text = web_notices()
    inventory = {"swift": swift, "app_fonts": font_inventory(APP_FONTS, APP_FONT_FILES), "web_fonts": font_inventory(WEB_FONTS), "web_npm": npm_inventory("web/package-lock.json"), "image_tooling_npm": npm_inventory("ios/app-store-images/package-lock.json"), "fastlane_gems": gem_inventory()}
    write("licenses/dependency-inventory.json", json.dumps(inventory, indent=2, ensure_ascii=False) + "\n")
    write("ios/Herdcats/Resources/ThirdPartyNotices.txt", ios_text)
    write("web/public/third-party-notices.txt", web_text)
    print("Updated pinned dependency inventory and iOS/website notices.")


if __name__ == "__main__":
    main()
