#!/usr/bin/env python3
"""Additional behavior checks on the same local scratch database."""
import os
import subprocess
import uuid
from concurrent.futures import ThreadPoolExecutor

if os.environ.get('PGHOST') not in ('127.0.0.1', 'localhost') or os.environ.get('PGDATABASE') != 'questionnaires':
    raise SystemExit('Use only the local scratch questionnaires database')

def sql(query, success=True):
    p=subprocess.run(['psql','-X','-v','ON_ERROR_STOP=1','-At'],input=query,text=True,capture_output=True)
    assert (p.returncode==0)==success, p.stderr if success else 'Expected database denial'
    return p.stdout.strip()

sql("SET ROLE questionnaires_writer; SELECT questionnaires_api.reserve_lookup(repeat('b',64));")
for _ in range(29): sql("SET ROLE questionnaires_writer; SELECT questionnaires_api.reserve_lookup(repeat('b',64));")
sql("SET ROLE questionnaires_writer; SELECT questionnaires_api.reserve_lookup(repeat('b',64));",False)
sql("SET ROLE questionnaires_reader; SELECT questionnaires_api.reserve_lookup(repeat('c',64));",False)
sql("SET ROLE questionnaires_writer; SELECT questionnaires_api.reserve_lookup('unbounded-untrusted-identifier');",False)
# Shared admission must remain effective across concurrent application replicas.
with ThreadPoolExecutor(max_workers=8) as pool:
    results=list(pool.map(lambda _: subprocess.run(['psql','-X','-v','ON_ERROR_STOP=1','-At'],input="SET ROLE questionnaires_writer; SELECT questionnaires_api.reserve_lookup(repeat('c',64));",text=True,capture_output=True).returncode,range(36)))
assert results.count(0)==30
for currency in ['CAD','BRL','IDR','JPY','MYR','PHP','SAR','THB']:
    sql(f"INSERT INTO vending_customers.responses(request_key,version,venue_type,country,city,currency,answers) VALUES('{uuid.uuid4()}',1,'gym','JP','Synthetic venue','{currency}','{{\"consent\":true,\"website\":\"\"}}');")
sql("SET ROLE questionnaires_writer; SELECT * FROM questionnaires_api.rate_limits",False)
sql("BEGIN; INSERT INTO questionnaires_api.rate_limits(bucket,period,hits) VALUES('lookup-global',date_trunc('minute',now()),300) ON CONFLICT(bucket,period) DO UPDATE SET hits=300; SET LOCAL ROLE questionnaires_writer; SELECT questionnaires_api.reserve_lookup(repeat('d',64));",False)
print('GREEN: international currencies, shared lookup limits, concurrent admission and least privilege')
