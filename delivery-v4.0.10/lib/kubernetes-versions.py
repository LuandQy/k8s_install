#!/usr/bin/env python3
"""Discover supported Kubernetes versions from configs/vX.Y.Z.yaml.

The configs directory is the single on-disk registry for versions. This helper
is shared by CLI menus, validation and the Web schema; no caller may hardcode a
version list. A file is eligible only when its filename version and the
kube_version field agree.
"""
import argparse
import json
import re
import sys
from pathlib import Path

VERSION = re.compile(r'v(\d+)\.(\d+)\.(\d+)')
FIELD = re.compile(r'^\s*kube_version:\s*["\']?(v\d+\.\d+\.\d+)["\']?\s*(?:#.*)?$', re.MULTILINE)


def version_key(value):
    match = VERSION.fullmatch(value)
    if not match:
        raise ValueError('invalid Kubernetes version: ' + value)
    return tuple(int(part) for part in match.groups())


def discover(root):
    root = Path(root).resolve()
    configs = root / 'configs'
    found = []
    if not configs.is_dir():
        raise ValueError('缺少 configs 目录: ' + str(configs))
    for path in sorted(configs.glob('v*.yaml')):
        match = VERSION.fullmatch(path.stem)
        if not match:
            continue
        match_field = FIELD.search(path.read_text(encoding='utf-8'))
        if not match_field:
            raise ValueError('版本文件缺少 kube_version: ' + path.name)
        declared = match_field.group(1)
        if declared != path.stem:
            raise ValueError('文件名与 kube_version 不一致: ' + path.name + ' -> ' + declared)
        found.append(declared)
    if not found:
        raise ValueError('configs/ 下没有可用的 Kubernetes 版本文件')
    if len(set(found)) != len(found):
        raise ValueError('configs/ 存在重复 Kubernetes 版本')
    return sorted(set(found), key=version_key, reverse=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument('command', choices=('list', 'default', 'json', 'check'))
    parser.add_argument('version', nargs='?')
    args = parser.parse_args(argv)
    try:
        versions = discover(args.root)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2
    if args.command == 'list':
        print('\n'.join(versions))
    elif args.command == 'default':
        print(versions[0])
    elif args.command == 'json':
        print(json.dumps(versions))
    elif args.command == 'check':
        if args.version not in versions:
            print('不支持的 Kubernetes 版本: ' + str(args.version), file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
