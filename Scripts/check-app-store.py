#!/usr/bin/env python3
"""Check source assets and, optionally, an actual release archive. Standard library only."""
import json
import pathlib
import plistlib
import re
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise SystemExit(f'FAIL: {message}')


def plist(path):
    require(path.is_file(), f'Missing {path}')
    return plistlib.loads(path.read_bytes())


def manifest(path, expected):
    data = plist(path)
    require(data.get('NSPrivacyTracking') is False, f'Tracking declaration: {path}')
    reasons = {item['NSPrivacyAccessedAPIType']: set(item['NSPrivacyAccessedAPITypeReasons'])
               for item in data.get('NSPrivacyAccessedAPITypes', [])}
    for category, reason in expected.items():
        require(reason in reasons.get('NSPrivacyAccessedAPICategory' + category, set()),
                f'Missing {category}/{reason} in {path}')


APP_REASONS = {'UserDefaults': 'CA92.1', 'FileTimestamp': 'C617.1', 'DiskSpace': 'E174.1'}
SDK_REASONS = {'FileTimestamp': 'C617.1', 'SystemBootTime': '35F9.1'}
manifest(ROOT / 'Sources/PrivacyInfo.xcprivacy', APP_REASONS)
manifest(ROOT / 'Support/LiteRTLM/PrivacyInfo.xcprivacy', SDK_REASONS)
count = 0
for contents in sorted((ROOT / 'Apps/AnvilAI/Assets.xcassets').glob('*.appiconset/Contents.json')):
    for entry in json.loads(contents.read_text())['images']:
        path = contents.parent / entry['filename']
        data = path.read_bytes()
        require(data[:8] == b'\x89PNG\r\n\x1a\n', f'Invalid PNG: {path}')
        width, height, depth, color = struct.unpack('>IIBB', data[16:26])
        require((width, height) == (1024, 1024), f'Icon must be 1024 square: {path}')
        require(color not in (4, 6), f'Icon contains an alpha channel: {path}')
        offset = 8
        while offset + 12 <= len(data):
            size = struct.unpack('>I', data[offset:offset + 4])[0]
            require(data[offset + 4:offset + 8] != b'tRNS', f'Icon has transparency: {path}')
            offset += size + 12
        count += 1
print(f'PASS: {count} opaque 1024×1024 public app icons; app and SDK privacy manifests.')

metadata = ROOT / 'docs/app-store/en-US'
listing = json.loads((metadata / 'listing.json').read_text())
for key, limit in [('name', 30), ('subtitle', 30), ('promotional_text', 170), ('keywords', 100)]:
    require(len(listing[key]) <= limit, f'Listing {key} exceeds {limit} characters')
require(len((metadata / 'description.txt').read_text()) <= 4000, 'App description exceeds 4000 characters')
print('PASS: App Store listing text fits field limits.')

if len(sys.argv) > 1:
    archive = pathlib.Path(sys.argv[1]).resolve()
    app = archive / 'Products/Applications/AnvilAI.app'
    info = plist(app / 'Info.plist')
    require(info.get('CFBundleDisplayName') == 'Anvil AI', 'Incorrect public app name')
    require(not info['CFBundleIdentifier'].endswith('.dev'), 'Development bundle identifier')
    require(info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Not an iOS device archive')
    require(info.get('UIDeviceFamily') == [1], 'Unexpected device families')
    require(info.get('ITSAppUsesNonExemptEncryption') is False, 'Missing encryption declaration')
    require(not info.get('BraveSearchAPIKey'), 'An API key is embedded in the release')
    require(info.get('AnvilHost') == 'www.anvilai.com', 'Not the production server')
    require(int(info.get('DTXcode', '0')) >= 2600, 'Xcode is older than 26')
    require(int(info.get('DTSDKName', 'iphoneos0').removeprefix('iphoneos').split('.')[0]) >= 26,
            'iOS SDK is older than 26')
    for key in ('CFBundleShortVersionString', 'CFBundleVersion'):
        require(re.fullmatch(r'\d+(\.\d+){0,2}', info[key]), f'Invalid {key}')
    for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription',
                'NSSpeechRecognitionUsageDescription'):
        require(bool(info.get(key)), f'Missing {key}')
    require(info.get('CFBundleIcons', {}).get('CFBundlePrimaryIcon', {}).get('CFBundleIconName'),
            'Primary app icon missing from bundle metadata')
    manifest(app / 'PrivacyInfo.xcprivacy', APP_REASONS)
    manifest(app / 'Frameworks/CLiteRTLM.framework/PrivacyInfo.xcprivacy', SDK_REASONS)
    require((archive / 'dSYMs/AnvilAI.app.dSYM').is_dir(), 'Missing app debug symbols')
    # codesign verifies nested framework seals too, when this is a signed archive.
    if (app / '_CodeSignature').exists():
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        profile = app / 'embedded.mobileprovision'
        require(profile.is_file(), 'Signed device app has no provisioning profile')
        decoded = subprocess.run(['security', 'cms', '-D', '-i', str(profile)],
                                 check=True, capture_output=True)
        entitlements = plistlib.loads(decoded.stdout)['Entitlements']
        require(entitlements.get('com.apple.developer.kernel.increased-memory-limit') is True,
                'Provisioning profile lacks Increased Memory Limit')
    print(f"PASS: {info['CFBundleDisplayName']} {info['CFBundleShortVersionString']} "
          f"({info['CFBundleVersion']}); {info['CFBundleIdentifier']}; {info['DTSDKName']}.")
    print(f'PASS: release bundle, purpose strings, production server, privacy resources and dSYM: {archive}')
