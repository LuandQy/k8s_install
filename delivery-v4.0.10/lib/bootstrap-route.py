#!/usr/bin/env python3
"""Pure bootstrap naming/routing rules; no node access or package installation."""
import argparse
import json
import re
from pathlib import Path

ARCH_ALIASES = {
    'x86_64': ('amd64',), 'amd64': ('amd64',),
    'aarch64': ('arm64', 'aarch64'), 'arm64': ('arm64', 'aarch64'),
}


def parse_os_release(text):
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        values[key] = value.strip().strip('"').strip("'")
    return values


def distro_token(values):
    ident = (values.get('ID') or '').lower()
    version = (values.get('VERSION_ID') or '').lower()
    codename = (values.get('VERSION_CODENAME') or '').lower()
    if ident == 'ubuntu':
        if codename in ('jammy', 'noble'):
            return codename
        return {'22.04': 'jammy', '24.04': 'noble'}.get(version, 'ubuntu' + version.replace('.', ''))
    if ident in ('kylin', 'neokylin'):
        # Kylin V10 SP3 is named ky10 in the delivery contract.
        if version.startswith('10') or 'v10' in version:
            return 'ky10'
        return 'kylin' + re.sub(r'[^a-z0-9]', '', version)
    return re.sub(r'[^a-z0-9]', '', ident or 'unknown')


def route(os_release, machine, bootstrap_dir):
    """Return candidate archive names and the first regular verified candidate."""
    values = parse_os_release(os_release) if isinstance(os_release, str) else dict(os_release)
    distro = distro_token(values)
    tokens = ARCH_ALIASES.get(machine.lower(), (machine.lower(),))
    directory = Path(bootstrap_dir)
    candidates = []
    for arch in tokens:
        candidates.append('bootstrap-%s-%s.tar.gz' % (distro, arch))
    selected = next((name for name in candidates if (directory / name).is_file()), None)
    return {'id': values.get('ID', ''), 'version': values.get('VERSION_ID', ''),
            'codename': values.get('VERSION_CODENAME', ''), 'distro_token': distro,
            'arch_tokens': list(tokens), 'candidates': candidates, 'selected': selected}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--os-release', required=True)
    parser.add_argument('--machine', required=True)
    parser.add_argument('--bootstrap-dir', required=True)
    args = parser.parse_args(argv)
    text = Path(args.os_release).read_text(encoding='utf-8')
    print(json.dumps(route(text, args.machine, args.bootstrap_dir), ensure_ascii=False))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
