#!/usr/bin/env python3
"""Capture current Herdcats simulator UI with built-in demonstration data.

Requires a booted simulator, a freshly built Debug .app, and Pillow.
No SSH credentials, real conversations, or remote installation are used.
"""
import argparse
from datetime import datetime, timezone
import plistlib
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time
from PIL import Image

SCREENS = [
    ('timeline-light', 'compose', True, 'NO'),
    ('timeline-dark', 'compose', False, 'NO'),
    ('terminal-compose', 'compose', True, 'NO'),
    ('voice', 'voice', True, 'NO'),
    ('bridge-setup', 'timeline-helper-missing', True, 'YES'),
    ('approval', 'timeline-approval-claude', True, 'YES'),
]
BUNDLE_ID = 'com.enchantinglabs.herdrcat'


def simctl(*args, check=True):
    return subprocess.run(['xcrun', 'simctl', *args], check=check, capture_output=True, text=True, timeout=90)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='UDID of a dedicated, booted simulator')
    parser.add_argument('--app', required=True, type=Path, help='Current Debug simulator .app')
    parser.add_argument('--raw-dir', type=Path, help='Keep original full-resolution PNGs here')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'public/assets/app')
    parser.add_argument('--only', nargs='+', choices=[s[0] for s in SCREENS], help='Recapture selected screens')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    raw_dir = args.raw_dir or Path(tempfile.mkdtemp(prefix='herdcats-app-screenshots-'))
    raw_dir.mkdir(parents=True, exist_ok=True)
    simctl('install', args.device, str(args.app.resolve()))
    simctl('status_bar', args.device, 'override', '--time', '9:41', '--batteryState', 'charged',
           '--batteryLevel', '100', '--cellularMode', 'active', '--cellularBars', '4', '--wifiBars', '3')
    manifest_path = args.output / 'manifest.json'
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else []
    with (args.app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=Path(__file__).resolve().parents[2], text=True).strip()
    try:
        for name, screen, light, compose in SCREENS:
            if args.only and name not in args.only:
                continue
            simctl('terminate', args.device, BUNDLE_ID, check=False)
            launch_args = ['-hc.screenshots', '-hc.screen', screen, '-paneShowComposeByDefault', compose,
                           '-timeline-setup-deferred.u=demo|h=studio-mac|p=22',
                           'YES' if name in ('terminal-compose', 'voice') else 'NO',
                           '-AppleLanguages', '(en)', '-AppleLocale', 'en_US']
            if light:
                launch_args.append('-hc.light')
            simctl('launch', args.device, BUNDLE_ID, *launch_args)
            time.sleep(12)  # Let initial navigation, fixture loading, and sheet animations settle.
            original = raw_dir / f'{name}.png'
            simctl('io', args.device, 'screenshot', str(original))
            with Image.open(original) as image:
                original_size = list(image.size)
                image = image.convert('RGB')
                image.thumbnail((600, 2000), Image.Resampling.LANCZOS)
                destination = args.output / f'{name}.webp'
                image.save(destination, 'WEBP', quality=90, method=6)
                manifest = [m for m in manifest if m['file'] != destination.name]
                manifest.append({'file': destination.name, 'fixture': screen, 'light': light,
                                 'captured_at_utc': datetime.now(timezone.utc).isoformat(),
                                 'source_revision': revision, 'app_version': info['CFBundleShortVersionString'],
                                 'app_build': info['CFBundleVersion'],
                                 'compose_default': compose, 'launch_arguments': launch_args,
                                 'original_size': original_size, 'web_size': list(image.size),
                                 'original_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
                                 'sha256': hashlib.sha256(destination.read_bytes()).hexdigest()})
            print(f'Captured {name}: {destination.stat().st_size:,} bytes', flush=True)
    finally:
        simctl('status_bar', args.device, 'clear', check=False)
        simctl('terminate', args.device, BUNDLE_ID, check=False)
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Original PNGs: {raw_dir}')


if __name__ == '__main__':
    main()
