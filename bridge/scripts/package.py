#!/usr/bin/env python3
"""Package a native release binary with its per-platform checksum."""
import argparse
import gzip
import hashlib
import json
import re
from pathlib import Path
import shutil
import subprocess
import tarfile
import io


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--platform', choices=['darwin-arm64', 'darwin-x86_64', 'linux-arm64', 'linux-x86_64'], required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        raise SystemExit("Invalid release version")
    info = json.loads(subprocess.check_output([str(args.binary.resolve()), '--version-json'], timeout=5))
    if info.get('version') != args.version or info.get('protocol') != 1:
        raise SystemExit('Package version/protocol mismatch')
    args.out.mkdir(parents=True, exist_ok=True)
    asset = args.out / ('herdcats-bridge-' + args.platform)
    shutil.copyfile(args.binary, asset)
    asset.chmod(0o755)
    digest = hashlib.sha256(asset.read_bytes()).hexdigest()
    installer = Path(__file__).with_name('install.sh').read_text()
    installer, count = re.subn(r'^HB_VERSION=.*$', 'HB_VERSION=' + args.version, installer, flags=re.M)
    if count != 1:
        raise SystemExit('Missing installer version default')
    # Preserve the historical template for the app-pinned installer checksum.
    # New packages carry the verified binary's agent contract.
    if tuple(map(int, args.version.split('.'))) >= (0, 4, 0):
        agents = info.get('agents')
        if not isinstance(agents, list) or not agents or any(
            not isinstance(agent, str) or not re.fullmatch(r'[a-z_]+', agent)
            for agent in agents
        ):
            raise SystemExit('Invalid package agent contract')
        contract_agents = json.dumps(agents, separators=(',', ':'))
        installer = installer.replace('"agents":["claude","codex"]', '"agents":' + contract_agents)
    # Ship one platform-independent extension alongside the arm64 Mac asset.
    # Fixed metadata makes its checksum reproducible across source checkouts.
    if 'pi' in info.get('agents', []) and args.platform == 'darwin-arm64':
        extension = args.out / 'herdcats-pi-extension.tar.gz'
        with extension.open('wb') as output, gzip.GzipFile(fileobj=output, mode='wb', filename='', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w') as archive:
                for name in ['index.ts', 'runtime.mjs', 'README.md']:
                    data = (Path(__file__).resolve().parents[1] / 'pi-extension' / name).read_bytes()
                    entry = tarfile.TarInfo('herdcats/' + name)
                    entry.size = len(data)
                    entry.mode = 0o644
                    archive.addfile(entry, io.BytesIO(data))
        (args.out / 'SHA256SUMS-pi-extension').write_text(
            hashlib.sha256(extension.read_bytes()).hexdigest() + '  ' + extension.name + '\n')
    (args.out / 'install.sh').write_text(installer)
    (args.out / ('SHA256SUMS-' + args.platform)).write_text(digest + '  ' + asset.name + '\n')


if __name__ == '__main__':
    main()
