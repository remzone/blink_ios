#!/usr/bin/env python3
"""Static configuration guards; NOT a Swift compiler or iOS build."""
from pathlib import Path
import plistlib
import json
import base64
import re
import sys
import yaml
root = Path(__file__).resolve().parents[1]
project = yaml.safe_load((root / 'project.yml').read_text())
assert {'path': 'fixtures', 'buildPhase': 'resources'} in project['targets']['BlinkTests']['sources']
new = project['targets']['BlinkXrayTunnel']
assert new['dependencies'] == [{'framework': 'Native/dist/BlinkCore.xcframework', 'embed': False}, {'sdk': 'libresolv.tbd'}]
app = project['targets']['Blink']
assert {'framework': 'Native/dist/BlinkCore.xcframework', 'embed': False} in app['dependencies']
assert {'sdk': 'libresolv.tbd'} in app['dependencies']
assert 'BlinkPacketTunnel' not in project['targets'], 'legacy multiple Go runtime target must stay retired'
assert project['settings']['base']['TARGETED_DEVICE_FAMILY'] == '1,2'
assert len([d for d in app['dependencies'] if 'framework' in d]) == 1
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
fixture = json.loads((root / 'fixtures/vokop.subscription.v1.json').read_text())
test_source = (root / 'BlinkTests/VokopSubscriptionTests.swift').read_text()
embedded = re.search(r'private let fixture = #"(.*?)"#', test_source).group(1)
assert json.loads(embedded) == fixture, 'Swift fixture drift'
assert fixture['schema'] == 'vokop.subscription.v1'
standard = (root / 'fixtures/standard-subscription.txt').read_bytes()
assert base64.decodebytes((root / 'fixtures/standard-subscription.base64').read_bytes()) == standard
expected = json.loads((root / 'fixtures/standard-subscription.expected.json').read_text())
assert len(standard.decode().splitlines()) == expected['total'] == 4
assert expected['supported'] == 2 and expected['rejected'] == 2
transport = (root / 'Blink/Services/SecureSubscriptionHTTP.swift').read_text()
for guard in ['URLSessionConfiguration.ephemeral', 'configuration.urlCredentialStorage = nil', 'completionHandler(nil)', 'data.count < Self.maximumBytes']:
    assert guard in transport, guard
def check_subscription_contract(view, model, client):
    """Narrow cross-file API guard, not general Swift name/type checking."""
    stored = re.search(r'struct SavedVokopSubscription[^{}]*\{([^{}]*)\}', model)
    assert stored, 'SavedVokopSubscription declaration missing'
    fields = set(re.findall(r'\blet\s+(\w+)\s*:', stored.group(1)))
    members = set(re.findall(r'\bstate\.(\w+)', view))
    assert members <= fields, f'SubscriptionView references unknown saved members: {members - fields}'
    for initializer in re.findall(r'SavedVokopSubscription\(([^()]*?)\)', view):
        labels = set(re.findall(r'\b(\w+)\s*:', initializer))
        assert labels == fields, f'Saved subscription initializer labels differ: {labels} vs {fields}'
    signature = re.search(r'func fetch\(([^()]*)\)', client)
    assert signature, 'VokopSubscriptionClient.fetch declaration missing'
    parameters = set(re.findall(r'\b(\w+)\s*:', signature.group(1)))
    for label in re.findall(r'VokopSubscriptionClient\(\)\.fetch\([^,\n]+,\s*(\w+)\s*:', view):
        assert label in parameters, f'Unknown subscription fetch argument: {label}'

check_subscription_contract(
    (root / 'Blink/UI/SubscriptionView.swift').read_text(),
    (root / 'Blink/Models/VokopSubscription.swift').read_text(),
    (root / 'Blink/Services/VokopSubscriptionClient.swift').read_text(),
)
print('PASS subscription view/model/client API names (targeted static guard, not Swift type checking)')

# Execute the literal Swift regex as a narrow source contract check. This is
# not Swift execution: it catches panel/client domain drift on the Linux host.
model = (root / 'Blink/Models/VokopSubscription.swift').read_text()
call_literal = re.search(r'Self.matches\(profile.turn.vk_call_url, "([^"\n]+)"\)', model)
assert call_literal, 'VK call URL validation pattern missing'
call_pattern = re.compile(json.loads('"' + call_literal.group(1) + '"'))
for host in ['vk.com', 'www.vk.com', 'vk.ru', 'www.vk.ru']:
    assert call_pattern.fullmatch('https://' + host + '/call/join/TEST_ONLY'), host
for value in ['https://vk.ru.evil.example/call/join/TEST_ONLY',
              'https://evilvk.com/call/join/TEST_ONLY',
              'http://vk.ru/call/join/TEST_ONLY',
              'https://vk.ru:443/call/join/TEST_ONLY',
              'https://user@vk.ru/call/join/TEST_ONLY',
              'https://vk.ru/call/join/TEST_ONLY?extra=1',
              'https://vk.ru/call/join/TEST_ONLY#extra',
              'https://vk.ru/call/join/TEST%2FONLY',
              'https://vk.ru/call/join/TEST_ONLY/extra',
              'https://vk.ru/call/join/TEST_ONLY\n']:
    assert not call_pattern.fullmatch(value), 'Malformed VK call accepted by source pattern'
print('PASS VK call URL source pattern: vk.com/vk.ru and exact secure paths (not Swift execution)')


print('PASS standard subscription fixture encoding and secure HTTP source guards (not Swift execution)')
print('PASS canonical panel subscription fixture matches Swift test fixture')
print('PASS static project/workflow/entitlement/public packetFlow guards (not Swift type checking)')
if '--swift-syntax' in sys.argv:
    from tree_sitter import Language, Parser
    import tree_sitter_swift
    parser = Parser(Language(tree_sitter_swift.language()))
    files = [*root.glob('Blink/**/*.swift'), *root.glob('BlinkTests/**/*.swift')]
    failures = [str(p) for p in files if parser.parse(p.read_bytes()).root_node.has_error]
    assert not failures, failures
    print(f'PASS syntax parser: {len(files)} Swift files (not compilation/XCTest)')
