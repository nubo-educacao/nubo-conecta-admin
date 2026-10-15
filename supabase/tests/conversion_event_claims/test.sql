-- NUB-RD-85 — teste de 20261015140000_conversion_event_claims.sql
--
-- Roda dentro de uma transação e termina em ROLLBACK: nenhuma fixture fica.
-- Pré-requisito: a migration aplicada (Supabase local do CI, ou Postgres puro
-- com stub_auth.sql antes). Qualquer contrato violado aborta com EXCEPTION.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/conversion_event_claims/test.sql

begin;

-- Identidades fictícias, só desta transação.
--   a1 conta nova (cadastro depois do corte)
--   a2 conta anterior ao corte (sem elegibilidade)
--   a3 sessão anônima
--   a4 segunda pessoa (isolamento)
insert into auth.users (id, phone, raw_user_meta_data)
values ('00000000-0000-4000-8000-0000000000a1', '5500000000001', '{}'::jsonb),
       ('00000000-0000-4000-8000-0000000000a2', '5500000000002', '{}'::jsonb),
       ('00000000-0000-4000-8000-0000000000a4', '5500000000004', '{}'::jsonb);
insert into auth.users (id, is_anonymous, raw_user_meta_data)
values ('00000000-0000-4000-8000-0000000000a3', true, '{}'::jsonb);

-- a2 simula conta criada antes do trigger existir.
delete from public.conversion_event_claims
 where user_id = '00000000-0000-4000-8000-0000000000a2';

create temp table r (step text primary key, event_id uuid, should_emit boolean);

create function pg_temp.claim(p_step text, p_user uuid, p_kind text, p_req uuid)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  insert into r select p_step, c.event_id, c.should_emit
                  from public.claim_conversion_event(p_kind, p_req) c;
  perform set_config('request.jwt.claims', '', true);
end $$;

do $$
declare n int;
begin
  -- Elegibilidade marcada no cadastro, nunca para sessão anônima.
  select count(*) into n from public.conversion_event_claims
   where user_id = '00000000-0000-4000-8000-0000000000a1' and kind = 'lead'
     and eligible_at is not null and claimed_at is null;
  if n <> 1 then raise exception 'FALHA: conta nova sem elegibilidade de Lead'; end if;

  select count(*) into n from public.conversion_event_claims
   where user_id = '00000000-0000-4000-8000-0000000000a3';
  if n <> 0 then raise exception 'FALHA: sessão anônima ficou elegível a Lead'; end if;
end $$;

-- Lead antes da confirmação: nada.
select pg_temp.claim('lead_unconfirmed', '00000000-0000-4000-8000-0000000000a1', 'lead',
                     '00000000-0000-4000-8000-0000000000b1');

update auth.users set phone_confirmed_at = now()
 where id in ('00000000-0000-4000-8000-0000000000a1',
              '00000000-0000-4000-8000-0000000000a2',
              '00000000-0000-4000-8000-0000000000a4');

-- Primeiro cadastro confirmado: aba 1 reivindica; retry do mesmo pedido repete;
-- outra aba / recarga / outro dispositivo (outro pedido) não emite.
select pg_temp.claim('lead_tab1',       '00000000-0000-4000-8000-0000000000a1', 'lead', '00000000-0000-4000-8000-0000000000b1');
select pg_temp.claim('lead_tab1_retry', '00000000-0000-4000-8000-0000000000a1', 'lead', '00000000-0000-4000-8000-0000000000b1');
select pg_temp.claim('lead_tab2',       '00000000-0000-4000-8000-0000000000a1', 'lead', '00000000-0000-4000-8000-0000000000b2');
-- Conta anterior ao corte fazendo login: nada.
select pg_temp.claim('lead_legacy',     '00000000-0000-4000-8000-0000000000a2', 'lead', '00000000-0000-4000-8000-0000000000b3');
-- Sessão anônima: nada.
select pg_temp.claim('lead_anon',       '00000000-0000-4000-8000-0000000000a3', 'lead', '00000000-0000-4000-8000-0000000000b4');
-- Segunda pessoa: evento próprio.
select pg_temp.claim('lead_other',      '00000000-0000-4000-8000-0000000000a4', 'lead', '00000000-0000-4000-8000-0000000000b5');

-- CompleteRegistration: antes de persistir, nada; depois, uma vez.
select pg_temp.claim('cr_not_persisted', '00000000-0000-4000-8000-0000000000a1', 'complete_registration', '00000000-0000-4000-8000-0000000000c1');
update auth.users set raw_user_meta_data = '{"onboarding_completed": true}'::jsonb
 where id = '00000000-0000-4000-8000-0000000000a1';
select pg_temp.claim('cr_first',  '00000000-0000-4000-8000-0000000000a1', 'complete_registration', '00000000-0000-4000-8000-0000000000c1');
select pg_temp.claim('cr_retry',  '00000000-0000-4000-8000-0000000000a1', 'complete_registration', '00000000-0000-4000-8000-0000000000c1');
-- "Refazer Match": novo submit = novo pedido.
select pg_temp.claim('cr_refazer', '00000000-0000-4000-8000-0000000000a1', 'complete_registration', '00000000-0000-4000-8000-0000000000c2');

do $$
declare
  rec r%rowtype;
  lead_id uuid;
  cr_id uuid;
  other_id uuid;
begin
  if exists (select 1 from r where step in ('lead_unconfirmed', 'lead_legacy', 'lead_anon', 'cr_not_persisted')) then
    raise exception 'FALHA: evento devolvido sem cadastro confirmado/elegível ou sem persistência: %',
      (select string_agg(step, ',') from r where step in ('lead_unconfirmed', 'lead_legacy', 'lead_anon', 'cr_not_persisted'));
  end if;

  select * into rec from r where step = 'lead_tab1';
  if rec.event_id is null or rec.should_emit is not true then raise exception 'FALHA: primeiro cadastro não reivindicou'; end if;
  lead_id := rec.event_id;

  select * into rec from r where step = 'lead_tab1_retry';
  if rec.event_id is distinct from lead_id or rec.should_emit is not true then
    raise exception 'FALHA: retry do mesmo pedido não repetiu o mesmo event_id';
  end if;

  select * into rec from r where step = 'lead_tab2';
  if rec.event_id is distinct from lead_id or rec.should_emit is not false then
    raise exception 'FALHA: outra aba/pedido voltou a emitir Lead';
  end if;

  select * into rec from r where step = 'cr_first';
  if rec.event_id is null or rec.should_emit is not true then raise exception 'FALHA: primeira conclusão não reivindicou'; end if;
  cr_id := rec.event_id;

  select * into rec from r where step = 'cr_retry';
  if rec.event_id is distinct from cr_id or rec.should_emit is not true then
    raise exception 'FALHA: retry da conclusão mudou o event_id';
  end if;

  select * into rec from r where step = 'cr_refazer';
  if rec.event_id is distinct from cr_id or rec.should_emit is not false then
    raise exception 'FALHA: Refazer Match voltou a emitir CompleteRegistration';
  end if;

  select event_id into other_id from r where step = 'lead_other';
  if other_id is null or other_id in (lead_id, cr_id) or lead_id = cr_id then
    raise exception 'FALHA: event_id não é isolado por pessoa/evento';
  end if;

  -- Opaco: não é nem contém o UUID da pessoa.
  if lead_id::text like '%0000000000a1%' or cr_id::text like '%0000000000a1%' then
    raise exception 'FALHA: event_id derivado do UUID da pessoa';
  end if;
end $$;

-- Erros de contrato.
do $$
begin
  begin
    perform public.claim_conversion_event('lead', '00000000-0000-4000-8000-0000000000b9');
    raise exception 'FALHA: chamada sem sessão foi aceita';
  exception when insufficient_privilege then null;
  end;

  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-4000-8000-0000000000a1"}', true);
  begin
    perform public.claim_conversion_event('purchase', '00000000-0000-4000-8000-0000000000b9');
    raise exception 'FALHA: kind inválido aceito';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.claim_conversion_event('lead', null);
    raise exception 'FALHA: p_request_id nulo aceito';
  exception when null_value_not_allowed then null;
  end;
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Privilégios: só authenticated executa; ninguém lê/escreve a tabela direto.
do $$
begin
  if has_function_privilege('anon', 'public.claim_conversion_event(text, uuid)', 'execute') then
    raise exception 'FALHA: anon pode executar claim_conversion_event';
  end if;
  if not has_function_privilege('authenticated', 'public.claim_conversion_event(text, uuid)', 'execute') then
    raise exception 'FALHA: authenticated não pode executar claim_conversion_event';
  end if;
  if has_function_privilege('authenticated', 'public.mark_lead_eligible()', 'execute')
     or has_function_privilege('anon', 'public.mark_lead_eligible()', 'execute') then
    raise exception 'FALHA: função de trigger exposta';
  end if;
  if has_table_privilege('authenticated', 'public.conversion_event_claims', 'select')
     or has_table_privilege('authenticated', 'public.conversion_event_claims', 'insert')
     or has_table_privilege('authenticated', 'public.conversion_event_claims', 'update')
     or has_table_privilege('anon', 'public.conversion_event_claims', 'select') then
    raise exception 'FALHA: tabela acessível diretamente';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.conversion_event_claims'::regclass) then
    raise exception 'FALHA: RLS desligado';
  end if;
  if exists (select 1 from pg_proc p
              where p.oid in ('public.claim_conversion_event(text, uuid)'::regprocedure,
                              'public.mark_lead_eligible()'::regprocedure)
                and not (coalesce(p.proconfig, '{}') @> array['search_path=""'])) then
    raise exception 'FALHA: SECURITY DEFINER sem search_path fixo';
  end if;
end $$;

do $$ begin raise notice 'conversion_event_claims OK'; end $$;

rollback;
