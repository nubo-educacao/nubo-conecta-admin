// Postgres embutido (PGlite) com a migration REAL das agregações do Command
// Center (NUB-RD-93). As Edges rodam pelo edgeHarness e o `rpc` do cliente
// executa as funções de verdade aqui: o teste confere SQL + Edge juntos, com os
// mesmos valores esperados de antes da migração do recorte para o banco.
import { PGlite } from '@electric-sql/pglite';
import { readdirSync, readFileSync } from 'node:fs';

const migrationsDir = new URL('../../supabase/migrations/', import.meta.url);
const file = (name: string) => readFileSync(new URL(name, migrationsDir), 'utf8');

export const AGGREGATES_MIGRATION = readdirSync(migrationsDir).find(name => /^\d{14}_cc_attribution_sql_aggregates\.sql$/.test(name));

// Só o bloco dos helpers do TP-7 (o restante recria RPCs de Estudantes).
const tp7 = file('20261015202330_tp7_first_touch_attribution_filters.sql');
const tp7Helpers = tp7.slice(0, tp7.indexOf('-- ─── get_students_paginated'));

const SCHEMA = `
  CREATE ROLE authenticated; CREATE ROLE anon; CREATE ROLE service_role; CREATE ROLE partner IN ROLE authenticated;
  CREATE SCHEMA auth;
  CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS
    $$ SELECT nullif(current_setting('test.role', true), '') $$;
  CREATE FUNCTION public.is_backoffice_admin() RETURNS boolean LANGUAGE sql AS
    $$ SELECT coalesce(current_setting('test.admin', true), '') = 'true' $$;
  CREATE TABLE channel_links (id uuid PRIMARY KEY, campaign_id uuid, channel_id uuid NOT NULL, archived_at timestamptz);
  CREATE TABLE user_attribution (user_id uuid PRIMARY KEY, first_touch_link_id uuid, last_touch_link_id uuid);
  CREATE TABLE user_profiles (id uuid PRIMARY KEY, full_name text, city text);
  CREATE TABLE chat_messages (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid, sender text, created_at timestamptz);
  CREATE TABLE user_favorites (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid NOT NULL, created_at timestamptz NOT NULL);
  CREATE TABLE user_preferences (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_id uuid UNIQUE NOT NULL, updated_at timestamptz,
    course_interest text[], program_preference text, location_preference text);
`;

const COLUMNS: Record<string, string[]> = {
  channel_links: ['id', 'campaign_id', 'channel_id', 'archived_at'],
  user_attribution: ['user_id', 'first_touch_link_id', 'last_touch_link_id'],
  user_profiles: ['id', 'full_name', 'city'],
  chat_messages: ['id', 'user_id', 'sender', 'created_at'],
  user_favorites: ['id', 'user_id', 'created_at'],
  user_preferences: ['id', 'user_id', 'updated_at', 'course_interest', 'program_preference', 'location_preference'],
};

export type Tables = Record<string, Record<string, unknown>[]>;

// Substitui o conteúdo das tabelas de fixture. Permite reutilizar uma única instância:
// subir um PGlite (WASM + schema + migrations) custa ~0,5 s localmente e bem mais num
// runner de CI de 2 vCPUs, então uma instância por chamada estoura o timeout de 5 s
// dos testes que a usam várias vezes (ex.: 4 rankings no mesmo `it`).
export async function seedAggregates(db: PGlite, tables: Tables) {
  await db.exec(`TRUNCATE ${Object.keys(COLUMNS).map(table => 'public.' + table).join(', ')}`);
  for (const [table, rows] of Object.entries(tables)) {
    const columns = COLUMNS[table];
    if (!columns) continue;
    for (const row of rows) {
      const present = columns.filter(column => row[column] !== undefined);
      await db.query(`INSERT INTO public.${table} (${present.join(', ')}) VALUES (${present.map((_, i) => '$' + (i + 1)).join(', ')})`,
        present.map(column => row[column]));
    }
  }
}

export async function aggregatesDb(tables: Tables) {
  if (!AGGREGATES_MIGRATION) throw new Error('migration *_cc_attribution_sql_aggregates.sql ausente');
  const db = new PGlite();
  await db.exec(SCHEMA);
  await db.exec(tp7Helpers);
  await db.exec(file(AGGREGATES_MIGRATION));
  await seedAggregates(db, tables);
  // As Edges chamam com o service client.
  await db.exec("SET test.role = 'service_role'");
  return db;
}

// Cliente supabase-js mínimo: auth do chamador, `rpc` executado no PGlite e
// `from` registrado (nenhuma Edge deve mais paginar tabela).
export function aggregatesClient(db: PGlite, { admin = true, total = 50 } = {}) {
  const rpcCalls: { fn: string; args: Record<string, unknown> }[] = [];
  const tableCalls: string[] = [];
  const client: any = {
    auth: {
      getUser: async () => ({ data: { user: { id: 'admin' } }, error: null }),
      admin: { listUsers: vi.fn(async () => ({ data: { total, users: [] }, error: null })) },
    },
    rpc: async (fn: string, args: Record<string, unknown> = {}) => {
      if (fn === 'is_backoffice_admin') return { data: admin, error: null };
      rpcCalls.push({ fn, args });
      const names = Object.keys(args);
      try {
        const result = await db.query<{ r: string }>(
          `SELECT public.${fn}(${names.map((name, i) => `${name} => $${i + 1}`).join(', ')})::text AS r`,
          names.map(name => args[name]));
        return { data: JSON.parse(result.rows[0].r), error: null };
      } catch (error: any) {
        return { data: null, error: { message: error.message, code: error.code } };
      }
    },
    from: (table: string) => { tableCalls.push(table); throw new Error(`consulta direta a ${table}`); },
  };
  return { client, rpcCalls, tableCalls };
}
