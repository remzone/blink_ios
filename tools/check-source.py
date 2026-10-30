#!/usr/bin/env python3
"""Static configuration guards; NOT a Swift compiler or iOS build."""
from pathlib import Path
import plistlib
import sys
import yaml
root = Path(__file__).resolve().parents[1]
project = yaml.safe_load((root / 'project.yml').read_text())
new = project['targets']['BlinkXrayTunnel']
assert new['dependencies'] == [{'framework': 'Native/dist/BlinkCore.xcframework', 'embed': False}]
assert 'XrayExtension' in project['targets']['Blink']['sources'][0]['excludes']
for workflow in (root / '.github/workflows').glob('*.yml'):
    # BaseLoader avoids YAML 1.1 treating the Actions key "on" as boolean True.
    doc = yaml.load(workflow.read_text(), Loader=yaml.BaseLoader)
    assert set(doc['on']) == {'workflow_dispatch'}, workflow
    assert all(job['runs-on'].startswith('macos') for job in doc['jobs'].values())
for entitlement in (root / 'Blink/Config').glob('*.entitlements'):
    plistlib.loads(entitlement.read_bytes())
provider = (root / 'Blink/XrayExtension/XrayPacketTunnelProvider.swift').read_text()
assert 'packetFlow.readPackets' in provider and 'packetFlow.writePackets' in provider
for unsupported in ['value(forKey:', 'getsockopt(', 'excludedRoutes =']:
    assert unsupported not in provider, unsupported
print('PASS static project/workflow/entitlement/public packetFlow guards (not Swift type checking)')
if '--swift-syntax' in sys.argv:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
    parser = Parser(Language(tree_sitter_swift.language()))
    files = [*root.glob('Blink/**/*.swift'), *root.glob('BlinkTests/**/*.swift')]
    failures = [str(p) for p in files if parser.parse(p.read_bytes()).root_node.has_error]
    assert not failures, failures
    print(f'PASS syntax parser: {len(files)} Swift files (not compilation/XCTest)')
