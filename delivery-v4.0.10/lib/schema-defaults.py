#!/usr/bin/env python3
"""Expose web/schema.json defaults to Bash without duplicating them."""
import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'web'))

import config_model  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', default=str(ROOT))
    parser.add_argument('--get')
    parser.add_argument('--shell', action='store_true')
    args = parser.parse_args(argv)
    try:
        spec = config_model.schema()
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2
    values = {field['key']: field.get('default') for field in spec['settings']}
    if args.get:
        if args.get not in values:
            print('未知配置键: ' + args.get, file=sys.stderr)
            return 2
        value = values[args.get]
        if isinstance(value, bool):
            print('true' if value else 'false')
        else:
            print('' if value is None else value)
        return 0
    if args.shell:
        for key in sorted(values):
            value = values[key]
            if isinstance(value, bool):
                value = 'true' if value else 'false'
            print('SCHEMA_DEFAULT_%s=%s' % (key, json.dumps(value, ensure_ascii=False)))
        return 0
    print(json.dumps(values, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
