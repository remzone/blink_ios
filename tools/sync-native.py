#!/usr/bin/env python3
"""Mirror the reviewed Android native source; never builds Apple artifacts."""
from pathlib import Path
import argparse
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--android', type=Path, default=root.parent / 'blink-android')
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
source = args.android / 'native'
target = root / 'Native'
old = b'github.com/remzone/blink-android/native'
new = b'github.com/remzone/blink_ios/native'
files = [Path('go.mod'), Path('go.sum'), Path('LICENSE')]
for folder in ('mobile', 'vkturn', 'share'):
    files += [p.relative_to(source) for p in (source / folder).rglob('*')
              if p.is_file() and (p.suffix == '.go' or p.name in ('LICENSE', 'UPSTREAM.md'))]
drift = []
for relative in sorted(files):
    data = (source / relative).read_bytes().replace(old, new)
    dest = target / relative
    if not dest.exists() or dest.read_bytes() != data:
        drift.append(str(relative))
        if not args.check:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
for folder in ('mobile', 'vkturn', 'share'):
    for p in (target / folder).rglob('*.go'):
        if p.relative_to(target) not in files:
            drift.append('stale ' + str(p.relative_to(target)))
            if not args.check:
                p.unlink()
if args.check and drift:
    sys.exit('Native mirror differs: ' + ', '.join(drift))
print(('PASS native mirror: ' if args.check else 'Updated native mirror: ') + str(len(files)) + ' files; no compilation')
