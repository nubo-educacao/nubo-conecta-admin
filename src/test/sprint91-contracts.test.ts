// @vitest-environment node
import { PGlite } from '@electric-sql/pglite';
import { readFileSync, readdirSync } from 'node:fs';
import { beforeAll, afterAll, describe, it, expect } from 'vitest';
const root = new URL('../../supabase/', import.meta.url);
let db: PGlite;
const read = (path: string) => readFileSync(new URL(path, root), 'utf8');
beforeAll(async () => {
 db = new PGlite();
 await db.exec(read('tests/sprint91_contracts/local_schema.sql'));
 const helper = read('migrations/20261015202330_tp7_first_touch_attribution_filters.sql');
 await db.exec(helper.slice(0, helper.indexOf('-- ─── get_students_paginated')));
 const names = readdirSync(new URL('migrations/', root)).filter(n => /_tpd_/.test(n)).sort();
 expect(names.length, 'migrations TP-D ausentes: RED').toBeGreaterThanOrEqual(4);
 for (const name of names) await db.exec(read('migrations/' + name));
}, 60000);
afterAll(async () => db?.close());
describe('TP-D real SQL contracts', () => {
 it('captures only first terminal conversions, immutable matched and unmatched snapshots, live activity and coverage', async () => {
   await db.exec('BEGIN');
   try { await db.exec(read('tests/sprint91_contracts/assert.sql')); } finally { await db.exec('ROLLBACK'); }
 });
 it('preserves v1 and its dependent view', async () => {
   const { rows } = await db.query("SELECT to_regprocedure('get_tp2_partner_funnel(uuid,integer)') IS NOT NULL old, to_regclass('vw_partner_funnel') IS NOT NULL view");
   expect(rows[0]).toEqual({old:true,view:true});
 });
});
