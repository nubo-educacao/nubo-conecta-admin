"""Staging-only TP-1 fixture: migration and data are always rolled back.
Run from the admin workspace: python supabase/tests/command-center/opportunity_interest_staging.py
Requires psycopg2, python-dotenv and STAGING_DATABASE_URL in .env.
"""
import os
from pathlib import Path
from urllib.parse import urlparse
from uuid import uuid4
import psycopg2
from dotenv import load_dotenv

load_dotenv('.env')
url = os.environ['STAGING_DATABASE_URL']
assert urlparse(url).hostname == 'db.yfgciamhzjvarwgzosto.supabase.co', 'Refusing non-staging target'
conn = psycopg2.connect(url, connect_timeout=10)
try:
    with conn.cursor() as cur:
        cur.execute("SET LOCAL lock_timeout = '3s'; SET LOCAL statement_timeout = '30s'")
        migration = Path('supabase/migrations/20261009193000_command_center_opportunity_interest.sql')
        cur.execute(migration.read_text(encoding='utf-8-sig'))
        cur.execute("SELECT user_id FROM public.user_permissions WHERE permission = 'Controle de usuários' LIMIT 1")
        admin = cur.fetchone()
        assert admin, 'Missing admin fixture'
        cur.execute("SELECT set_config('request.jwt.claim.sub', %s, true)", (str(admin[0]),))
        cur.execute("SELECT id FROM public.partner_opportunities ORDER BY id LIMIT 1")
        partner = cur.fetchone()
        cur.execute("SELECT o.id FROM public.opportunities o JOIN public.courses c ON c.id=o.course_id JOIN public.campus ca ON ca.id=c.campus_id JOIN public.institutions i ON i.id=ca.institution_id ORDER BY o.id LIMIT 1")
        mec = cur.fetchone()
        assert partner and mec, 'Missing partner/MEC opportunity fixtures'
        prefix = 'tp1-' + str(uuid4())
        rows = [
            ('card_click','partner_opportunity',partner[0],None,'card',3,'2099-10-02'),
            ('card_click','partner_opportunity',None,'partner_' + str(partner[0]),'card',4,'2099-10-03'),
            ('card_click','mec_opportunity',mec[0],None,'card',2,'2099-10-02'),
            ('card_click','mec_opportunity',None,'mec_' + str(mec[0]),'card',1,'2099-10-03'),
            ('card_click','partner_opportunity',partner[0],None,'legacy_partners_click_aggregate',100,'2099-10-02'),
            ('card_view','partner_opportunity',partner[0],None,'card',100,'2099-10-02'),
            ('redirect','partner_opportunity',partner[0],None,'card',100,'2099-10-02'),
            ('card_click','institution',partner[0],None,'card',100,'2099-10-02'),
            ('card_click','partner_opportunity',partner[0],None,'card',100,'2099-10-09'),
            ('card_click','partner_opportunity',uuid4(),None,'card',100,'2099-10-02'),
        ]
        for index, row in enumerate(rows):
            cur.execute("INSERT INTO public.engagement_events(event_id,anonymous_id,event_type,entity_type,entity_id,unified_opportunity_id,source,event_count,occurred_at,destination_url) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                (prefix + str(index), prefix, row[0],row[1],str(row[2]) if row[2] else None,row[3],row[4],row[5],row[6],'https://example.invalid/tp1'))
        cur.execute("SET LOCAL ROLE authenticated")
        cur.execute("SELECT opportunity_id,title,provider,clicks FROM public.get_command_center_opportunity_interest('2099-10-01','2099-10-09',10)")
        results = cur.fetchall()
        assert [(r[0],r[3]) for r in results] == [('partner_' + str(partner[0]),7),('mec_' + str(mec[0]),3)], results
        assert all(r[1] and r[2] for r in results), 'Missing real titles/providers'
        cur.execute("SELECT count(*) FROM public.get_command_center_opportunity_interest('2098-01-01','2098-01-02',10)")
        assert cur.fetchone()[0] == 0
        cur.execute("RESET ROLE")
        cur.execute("SELECT has_function_privilege('anon','public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer)','EXECUTE'),has_function_privilege('partner','public.get_command_center_opportunity_interest(timestamptz,timestamptz,integer)','EXECUTE')")
        privileges = cur.fetchone()
        assert privileges[0] is False  # partner inherits authenticated; authorization is enforced by the guard
        cur.execute("SAVEPOINT non_admin; SELECT set_config('request.jwt.claim.sub', %s, true); SET LOCAL ROLE authenticated", (str(uuid4()),))
        try:
            cur.execute("SELECT * FROM public.get_command_center_opportunity_interest('2099-10-01','2099-10-09',10)")
            raise AssertionError('Non-admin unexpectedly allowed')
        except psycopg2.errors.InsufficientPrivilege:
            cur.execute('ROLLBACK TO SAVEPOINT non_admin')
        cur.execute("SAVEPOINT partner_guard; SELECT set_config('request.jwt.claim.sub', %s, true); SET LOCAL ROLE partner", (str(uuid4()),))
        try:
            cur.execute("SELECT * FROM public.get_command_center_opportunity_interest('2099-10-01','2099-10-09',10)")
            raise AssertionError('Partner unexpectedly allowed')
        except psycopg2.errors.InsufficientPrivilege:
            cur.execute('ROLLBACK TO SAVEPOINT partner_guard')
        print('PASS staging: weighted ranking 7/3, fallback IDs, real titles/providers, period, empty state, admin guard and ACL')
finally:
    conn.rollback()
    conn.close()
    print('ROLLBACK: fixture and RPC changes not persisted')

