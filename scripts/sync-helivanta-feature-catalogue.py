#!/usr/bin/env python3
"""Project Helivanta's reviewed release contract into onboarding Helm values."""
import argparse
import json
from pathlib import Path
import yaml

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('contract', type=Path)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
schema_file = root / 'charts/apps/onboarding-service/values.schema.json'
schema = json.loads(schema_file.read_text())
schema['properties']['helivantaFeatureCatalogue']['properties']['catalogue'] = json.loads((root / 'charts/apps/onboarding-service/files/helivanta-catalogue.schema.json').read_text())
schema_rendered = json.dumps(schema, indent=2) + '\n'
if args.check:
    if schema_file.read_text() != schema_rendered:
        raise SystemExit('Helm schema differs from canonical catalogue schema')
else:
    schema_file.write_text(schema_rendered)
contract = json.loads(args.contract.read_text())
catalogue = {key: contract[key] for key in ('version', 'policy_version')}
catalogue['capabilities'] = [
    {**{key: row[key] for key in ('key', 'owner', 'eligible', 'dependencies')}, **({'pilot_eligible': True} if row.get('pilot_eligible') is True else {})}
    for row in contract['capabilities']
]
target = Path(__file__).resolve().parents[1] / 'charts/apps/onboarding-service/values-prod.yaml'
marker = '# Generated Helivanta feature catalogue; use scripts/sync-helivanta-feature-catalogue.py.\n'
before = target.read_text().split(marker)[0].rstrip() + '\n\n'
rendered = before + marker + yaml.safe_dump({'helivantaFeatureCatalogue': {'enabled': True, 'catalogue': catalogue}}, sort_keys=False)
if args.check:
    if target.read_text() != rendered:
        raise SystemExit('Helivanta feature catalogue differs; regenerate from release contract')
else:
    target.write_text(rendered)
