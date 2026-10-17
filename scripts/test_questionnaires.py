#!/usr/bin/env python3
"""Run against an empty scratch database named questionnaires using PG* variables."""
import os
import json
import pathlib
import subprocess
import uuid

if os.environ.get('PGHOST') not in ('127.0.0.1', 'localhost') or os.environ.get('PGDATABASE') != 'questionnaires':
    raise SystemExit('Use only an empty local scratch questionnaires database')

SCHEMA = pathlib.Path(__file__).resolve().parents[1] / 'charts/apps/db-schema-bootstrap/schemas/questionnaires/tesserix/001_questionnaires.sql'

def sql(query, success=True):
    p = subprocess.run(['psql', '-X', '-v', 'ON_ERROR_STOP=1', '-At'], input=query, text=True, capture_output=True)
    assert (p.returncode == 0) == success, p.stderr if success else 'Expected database denial'
    return p.stdout.strip()

sql("CREATE ROLE questionnaires_writer; CREATE ROLE questionnaires_reader;")
customer = {'version': 1, 'venueType': 'gym', 'country': 'AU', 'city': 'Melbourne', 'currency': 'AUD', 'products': ['water','protein-bars'], 'topProduct': 'water', 'consent': True, 'website': ''}
key = str(uuid.uuid4())
def submit(payload=customer, request_key=key, form='vending-customers', success=True):
    encoded=json.dumps(payload).replace("'", "''")
    return sql(f"SET ROLE questionnaires_writer; SELECT questionnaires_api.submit('{form}','{request_key}','{encoded}'::jsonb,repeat('a',64),300,400);",success)

submit(success=False)
print('RED: submission unavailable before schema, as expected')
sql(SCHEMA.read_text())
sql(SCHEMA.read_text())
assert submit().splitlines()[-1] == key
assert submit().splitlines()[-1] == key
assert sql('SELECT count(*) FROM vending_customers.responses;') == '1'
assert sql('SELECT count(*) FROM vending_customers.product_preferences;') == '2'
submit({**customer,'city':'Sydney'},success=False)
submit({**customer,'products':['not-a-product']},str(uuid.uuid4()),success=False)
assert sql('SELECT count(*) FROM vending_customers.responses;') == '1'
for table in ['vending_customers.responses','vending_business.responses','vending_customers.product_preferences']:
    sql('SET ROLE questionnaires_writer; SELECT * FROM '+table,False)
    sql('SET ROLE questionnaires_reader; DELETE FROM '+table,False)
    sql('SET ROLE questionnaires_reader; SELECT * FROM '+table)
sql("SET ROLE questionnaires_reader; SELECT questionnaires_api.submit('vending-customers',gen_random_uuid(),'{}',repeat('a',64),0,0)",False)
business={**customer,'businessName':'Synthetic venue','contactName':'Test','contactEmail':'test@example.org'}
assert submit(business, key, 'vending-business').splitlines()[-1] == key
assert sql('SELECT count(*) FROM vending_business.responses;') == '1'
decline={k:v for k,v in business.items() if k not in ('contactName','contactEmail')}
decline['commercialModel']='not-interested'
submit(decline,str(uuid.uuid4()),'vending-business')
from concurrent.futures import ThreadPoolExecutor
with ThreadPoolExecutor(max_workers=8) as pool:
    assert all(value.splitlines()[-1]==key for value in pool.map(lambda _: submit(),range(8)))
for _ in range(3): submit(request_key=str(uuid.uuid4()))
submit(request_key=str(uuid.uuid4()),success=False)
assert sql('SELECT count(*) FROM vending_customers.responses;') == '4'
assert submit().splitlines()[-1] == key
print('GREEN: isolated forms, least privilege, replay, conflicts, transactional preferences, rate limit and replay after limit passed')
