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
# Reviewed iOS-only runtime/diagnostic overrides must survive a mirror refresh.
# Upstream changes to these files require an explicit manual merge; see Native/IOS-OVERRIDES.md.
ios_overrides = {Path(p) for p in (
    'mobile/diagnostics.go', 'mobile/diagnostics_test.go',
    'mobile/diagnostic_log.go', 'mobile/diagnostic_log_test.go',
    'mobile/engine.go', 'mobile/wg_backend.go',
    'resources/assets.go', 'resources/assets_test.go',
    'vkturn/diagnostics.go', 'vkturn/diagnostics_test.go',
    'vkturn/captcha.go', 'vkturn/client.go', 'vkturn/credentials.go',
    'vkturn/transport.go', 'vkturn/turn_transport_test.go',
)}
files = [Path('go.mod'), Path('go.sum'), Path('LICENSE')]
for folder in ('mobile', 'vkturn', 'share', 'resources'):
    files += [p.relative_to(source) for p in (source / folder).rglob('*')
              if p.is_file() and (p.suffix == '.go' or p.name in ('LICENSE', 'UPSTREAM.md') or p.suffix == '.dat' or (p.suffix == '.json' and 'testdata' in p.parts))]
drift = []
for relative in sorted(files):
    if relative in ios_overrides:
        continue
    data = (source / relative).read_bytes().replace(old, new)
    dest = target / relative
    if not dest.exists() or dest.read_bytes() != data:
        drift.append(str(relative))
        if not args.check:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(data)
for folder in ('mobile', 'vkturn', 'share', 'resources'):
    for p in (target / folder).rglob('*.go'):
        if p.relative_to(target) not in files and p.relative_to(target) not in ios_overrides:
            drift.append('stale ' + str(p.relative_to(target)))
            if not args.check:
                p.unlink()
print('Preserved iOS overrides (manual upstream review required): ' + ', '.join(str(p) for p in sorted(ios_overrides)))
if args.check and drift:
    sys.exit('Native mirror differs: ' + ', '.join(drift))
print(('PASS native mirror: ' if args.check else 'Updated native mirror: ') + str(len(files)) + ' files; no compilation')
