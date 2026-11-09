#!/usr/bin/env python3
"""Cross-repo schema guard, not Swift execution. Never reads subscription credentials."""
import argparse
import json
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--panel', type=Path, default=root.parent / 'vokop-panel')
args = parser.parse_args()
source = (args.panel / 'internal/web/service/client_diagnostics.go').read_text()
arrays = re.findall(r'for _, s := range \[\]string\{([^}]+)\}', source)
assert len(arrays) == 2
allowed_events, allowed_fields = [set(re.findall(r'"([^"\n]+)"', a)) for a in arrays]
emitted = set()
for folder in ('Blink', 'Native/mobile', 'Native/vkturn'):
    for path in (root / folder).rglob('*'):
        if path.suffix not in ('.swift', '.go') or path.name.endswith('_test.go'):
            continue
        text = path.read_text()
        emitted.update(re.findall(r'(?:\.record|RecordDiagnostic|diagnosticStage)\("([a-z][a-z0-9_.]+)"', text))
assert emitted <= allowed_events, f'Unknown diagnostic events: {emitted - allowed_events}'
fixture = (root / 'fixtures/diagnostics.v1.json').read_bytes()
assert fixture == (args.panel / 'docs/vokop/fixtures/diagnostics.v1.json').read_bytes()
for event in json.loads(fixture):
    assert event['event'] in allowed_events
    assert set(event['fields']) <= allowed_fields
    assert all(isinstance(v, int) for v in event['fields'].values())
print(f'PASS {len(emitted)} emitted event identifiers and shared diagnostic wire fixture (static guard)')

# Diagnostic delivery is an explicit foreground action, never a connect/heartbeat side effect.
center = (root / 'Blink/Services/DiagnosticCenter.swift').read_text()
assert center.count('DiagnosticUploader.shared.flush()') == 1
assert 'DiagnosticUploader.shared.flush()' in center.split('func flushNow() async {', 1)[1].split('func resetLocal()', 1)[0]
assert 'DiagnosticUploader' not in (root / 'Blink/XrayExtension/XrayPacketTunnelProvider.swift').read_text()
print('PASS diagnostic delivery only from explicit foreground flushNow')
