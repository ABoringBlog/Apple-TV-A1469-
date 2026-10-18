#!/usr/bin/env python3
"""Inspect package contents without extracting or installing them (Mac ar required)."""
import io
import math
from pathlib import Path, PurePosixPath
import plistlib
import struct
import subprocess
import sys
import tarfile

ROOT = 'Applications/Jellyfin.frappliance'
LINK = 'Applications/AppleTV.app/Appliances/Jellyfin.frappliance'
PAYLOAD = {ROOT + '/Info.plist', ROOT + '/Jellyfin', ROOT + '/_CodeSignature/CodeResources'}
LOCALIZED = ROOT + '/English.lproj/InfoPlist.strings'
ICON = ROOT + '/AppIcon.png'
TOP_ICON = ROOT + '/TopRowIcon.png'
DIRECTORIES = {'', 'Applications', 'Applications/AppleTV.app', 'Applications/AppleTV.app/Appliances', ROOT, ROOT + '/English.lproj', ROOT + '/_CodeSignature'}

def require(condition, message):
    if not condition:
        raise ValueError(message)

def members(data):
    archive = tarfile.open(fileobj=io.BytesIO(data), mode='r:gz')
    found = {}
    for member in archive:
        name = member.name
        while name.startswith('./'):
            name = name[2:]
        name = name.rstrip('/')
        if name == '.':
            name = ''
        require(not name.startswith('/') and '..' not in PurePosixPath(name).parts, 'Unsafe archive path')
        require(name not in found, 'Duplicate archive member')
        require(member.uid == 0 and member.gid == 0, 'Archive ownership must be root:wheel (0:0)')
        require(member.issym() or not member.mode & 0o6022, 'Set-id or group/world-writable archive member')
        found[name] = member
    return archive, found

def verify(package, bundle=None):
    def part(name):
        return subprocess.check_output(['ar', '-p', str(package), name])
    require(subprocess.check_output(['ar', '-t', str(package)]).decode().split() ==
            ['debian-binary', 'control.tar.gz', 'data.tar.gz'], 'Unexpected Debian members')
    require(part('debian-binary') == b'2.0\n', 'Invalid Debian format')
    archive, files = members(part('control.tar.gz'))
    with archive:
        require(set(files) <= {'', 'control'} and 'control' in files, 'Unexpected control entry or maintainer script')
        require(files['control'].isfile(), 'Control is not a regular file')
        fields = {}
        for line in archive.extractfile(files['control']).read().decode().splitlines():
            key, separator, value = line.partition(': ')
            require(separator and key not in fields, 'Malformed or duplicate control field')
            fields[key] = value
        require(fields.get('Package') == 'org.jellyfin.atv3', 'Wrong package ID')
        require(fields.get('Architecture') == 'iphoneos-arm', 'Wrong package architecture')
        require(bool(fields.get('Version')), 'Missing package version')
    archive, files = members(part('data.tar.gz'))
    with archive:
        require(set(files) <= DIRECTORIES | PAYLOAD | {LINK, LOCALIZED, ICON, TOP_ICON}, 'Unexpected payload path')
        require(PAYLOAD | {LINK} <= set(files), 'Missing payload')
        for name, member in files.items():
            if name in DIRECTORIES:
                require(member.isdir() and member.mode == 0o755, 'Invalid directory type/mode')
            elif name == LINK:
                require(member.issym() and member.linkname == '/Applications/Jellyfin.frappliance', 'Wrong appliance symlink')
            else:
                require(member.isfile(), 'Payload must be a regular file')
                require(member.mode == (0o755 if name.endswith('/Jellyfin') else 0o644), 'Wrong payload mode')
        payload = {name: archive.extractfile(files[name]).read() for name in PAYLOAD | ({LOCALIZED, ICON, TOP_ICON} & set(files))}
        metadata = plistlib.loads(payload[ROOT + '/Info.plist'])
        expected = {'CFBundleExecutable': 'Jellyfin', 'NSPrincipalClass': 'JellyfinAppliance',
                    'CFBundleIdentifier': 'org.jellyfin.atv3', 'CFBundlePackageType': 'BNDL',
                    'CFBundleName': 'Jellyfin', 'FRApplianceName': 'Jellyfin',
                    'MinimumOSVersion': '8.0', 'CFBundleVersion': fields['Version'].split('-')[0]}
        require(all(metadata.get(key) == value for key, value in expected.items()), 'Bundle metadata/version mismatch')
        require(metadata.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Wrong bundle platform')
        order = metadata.get('FRAppliancePreferedOrderValue')
        require(type(order) in (int, float) and math.isfinite(order), 'Invalid float-convertible appliance order')
        # These are candidate consistency checks, not a claim every FRA key is required by beigelist.
        bundle_version = tuple(int(v) for v in metadata['CFBundleVersion'].split('.'))
        if bundle_version >= (0, 5, 1):
            require(metadata.get('CFBundleDevelopmentRegion') == 'English', 'Missing development region')
            require(LOCALIZED in payload, 'Missing loader localized name')
            require(plistlib.loads(payload[LOCALIZED]).get('CFBundleName') == 'Jellyfin', 'Wrong loader localized name')
        if bundle_version >= (0, 5, 2):
            require(ICON in payload, 'Missing legacy AppIcon.png')
            icon = payload[ICON]
            require(icon.startswith(b'\x89PNG\r\n\x1a\n') and len(icon) >= 24, 'Invalid AppIcon.png')
            width, height = struct.unpack_from('>II', icon, 16)
            require((width, height) == (188, 108), 'AppIcon.png must be 188x108')
        if bundle_version >= (0, 5, 3):
            require(TOP_ICON in payload, 'Missing legacy TopRowIcon.png')
            top_icon = payload[TOP_ICON]
            require(top_icon.startswith(b'\x89PNG\r\n\x1a\n') and len(top_icon) >= 26, 'Invalid TopRowIcon.png')
            width, height = struct.unpack_from('>II', top_icon, 16)
            require((width, height) == (188, 108), 'TopRowIcon.png must be 188x108')
            require(metadata.get('BLForceLegacyNav') is False, 'BLForceLegacyNav must be false for direct appliance navigation')
        if bundle_version >= (0, 5, 4):
            require(payload[ICON][25] == 6, 'AppIcon.png must be RGBA')
            require(payload[TOP_ICON][25] == 6, 'TopRowIcon.png must be RGBA')
        binary = payload[ROOT + '/Jellyfin']
        require(len(binary) >= 28, 'Truncated Mach-O')
        magic, cpu, subtype, kind, count, size, flags = struct.unpack_from('<7I', binary)
        require((magic, cpu, subtype & 0xffffff, kind) == (0xfeedface, 12, 9, 8), 'Expected thin ARMv7 Mach-O bundle')
        require(28 + size <= len(binary), 'Invalid load-command extent')
        offset, signed, minimum = 28, False, False
        for _ in range(count):
            require(offset + 8 <= 28 + size, 'Truncated load command')
            command, length = struct.unpack_from('<2I', binary, offset)
            require(length >= 8 and offset + length <= 28 + size, 'Invalid load command length')
            if command == 0x1d:
                require(length >= 16, 'Invalid signature command')
                start, length_of_signature = struct.unpack_from('<2I', binary, offset + 8)
                require(start > 0 and length_of_signature > 0 and start + length_of_signature <= len(binary), 'Invalid signature extent')
                signed = True
            if command == 0x25:
                require(length >= 16, 'Invalid minimum version command')
                minimum = struct.unpack_from('<I', binary, offset + 8)[0] == 0x80000
            offset += length
        require(offset == 28 + size and signed and minimum, 'Missing signature or iOS 8.0 build baseline')
        if bundle:
            for name, data in payload.items():
                require((Path(bundle) / name[len(ROOT)+1:]).read_bytes() == data, 'Archive differs from verified signed bundle')
    return fields['Version']

if __name__ == '__main__':
    try:
        if len(sys.argv) not in (2, 3):
            raise ValueError('Usage: verify-package.py PACKAGE [SIGNED_BUNDLE]')
        version = verify(*sys.argv[1:])
        print('PASS: package', version, 'paths/ownership/modes, metadata, ARMv7, signature presence, no maintainer scripts')
        print('NOT TESTED: Apple TV signature trust, loader and firmware compatibility')
    except (ValueError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print('FAIL:', error, file=sys.stderr)
        sys.exit(1)
