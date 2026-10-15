-- NUB-RD-85 (TP-7, regras R1–R4 aprovadas pelo humano em 12/10/2026)
--
-- Idempotência autoritativa dos eventos de conversão do navegador.
--
-- Por que no banco: o app recebia `SIGNED_IN` tanto em cadastro quanto em login
-- de conta existente, em outra aba (BroadcastChannel) e em recuperação de
-- sessão. Dedupe em useRef/localStorage não atravessa aba, recarga nem
-- dispositivo. Só o servidor sabe, de forma atômica, se o evento lógico
-- "primeiro cadastro" ou "primeira conclusão do onboarding" já aconteceu.
--
-- Delta mínimo: uma tabela sem acesso direto, um trigger que só MARCA
-- elegibilidade no cadastro e uma RPC que reivindica o evento uma vez.
--
--   · lead                   elegível só para conta criada depois deste corte
--                            (trigger em auth.users) e confirmada; contas
--                            anteriores nunca geram Lead em login.
--   · complete_registration  só quando `onboarding_completed` já está
--                            PERSISTIDO em auth.users; uma vez por conta.
--
-- `event_id` é aleatório e gerado aqui: não deriva da pessoa, é o mesmo em
-- qualquer retry do mesmo evento e poderá ser lido pelo envio server-side
-- futuro (CAPI, fora de escopo) para deduplicar navegador × servidor.
--
-- Esta tabela NÃO registra consentimento nem se o evento foi enviado a
-- terceiro: isso é decisão do encarregado (prova durável), fora deste delta.

create table if not exists public.conversion_event_claims (
  user_id          uuid        not null references auth.users (id) on delete cascade,
  kind             text        not null
                   constraint conversion_event_claims_kind_check
                   check (kind in ('lead', 'complete_registration')),
  event_id         uuid        not null default gen_random_uuid(),
  eligible_at      timestamptz,
  claimed_at       timestamptz,
  claim_request_id uuid,
  constraint conversion_event_claims_pkey primary key (user_id, kind),
  constraint conversion_event_claims_event_id_key unique (event_id),
  constraint conversion_event_claims_claim_consistency
    check ((claimed_at is null) = (claim_request_id is null))
);

comment on table public.conversion_event_claims is
  'NUB-RD-85: reivindicação única de eventos de conversão (Lead, CompleteRegistration). '
  'Sem acesso direto; só via claim_conversion_event. Não registra consentimento.';

alter table public.conversion_event_claims enable row level security;
-- Nenhuma policy de propósito: anon e authenticated não leem nem escrevem.
revoke all on table public.conversion_event_claims from public, anon, authenticated;

-- ── Elegibilidade do Lead: fonte autoritativa = criação da conta ─────────────

create or replace function public.mark_lead_eligible()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Sessão anônima não é cadastro.
  if coalesce(new.is_anonymous, false) then
    return new;
  end if;

  begin
    insert into public.conversion_event_claims (user_id, kind, eligible_at)
    values (new.id, 'lead', now())
    on conflict (user_id, kind) do nothing;
  exception when others then
    -- Perder um Lead custa uma linha de relatório; barrar o cadastro custa o
    -- cadastro. Nunca propagar.
    raise warning 'mark_lead_eligible: % (%)', sqlerrm, sqlstate;
  end;

  return new;
end;
$$;

revoke all on function public.mark_lead_eligible() from public, anon, authenticated;

drop trigger if exists on_auth_user_created_lead_eligibility on auth.users;
create trigger on_auth_user_created_lead_eligibility
  after insert on auth.users
  for each row execute function public.mark_lead_eligible();

-- ── Reivindicação ────────────────────────────────────────────────────────────
--
-- Devolve no máximo uma linha:
--   (event_id, true)   esta chamada reivindicou o evento → o navegador emite;
--                      repetir a MESMA chamada (mesmo p_request_id) devolve o
--                      mesmo par, para retry de transporte.
--   (event_id, false)  o evento já foi reivindicado por outro pedido (outra
--                      aba, outro dispositivo, recarga) → não emitir.
--   nenhuma linha      não há evento: conta anterior ao corte, não confirmada,
--                      anônima, ou onboarding ainda não persistido.

create or replace function public.claim_conversion_event(p_kind text, p_request_id uuid)
returns table (event_id uuid, should_emit boolean)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := auth.uid();
  v_confirmed boolean;
  v_anonymous boolean;
  v_completed boolean;
  v_event_id  uuid;
  v_request   uuid;
  v_claimed   timestamptz;
begin
  if v_uid is null then
    raise exception 'claim_conversion_event: requer sessão autenticada'
      using errcode = '42501';
  end if;
  if p_request_id is null then
    raise exception 'claim_conversion_event: p_request_id é obrigatório'
      using errcode = '22004';
  end if;
  if p_kind is null or p_kind not in ('lead', 'complete_registration') then
    raise exception 'claim_conversion_event: kind inválido'
      using errcode = '22023';
  end if;

  select (u.email_confirmed_at is not null or u.phone_confirmed_at is not null),
         coalesce(u.is_anonymous, false),
         coalesce(u.raw_user_meta_data ->> 'onboarding_completed', '') = 'true'
    into v_confirmed, v_anonymous, v_completed
    from auth.users u
   where u.id = v_uid;

  if not found or v_anonymous then
    return;
  end if;

  if p_kind = 'lead' then
    if not v_confirmed then
      return;
    end if;

    update public.conversion_event_claims c
       set claimed_at = now(),
           claim_request_id = p_request_id
     where c.user_id = v_uid
       and c.kind = 'lead'
       and c.eligible_at is not null
       and c.claimed_at is null
    returning c.event_id into v_event_id;

    if v_event_id is not null then
      return query select v_event_id, true;
      return;
    end if;
  else
    if not v_completed then
      return;
    end if;

    insert into public.conversion_event_claims (user_id, kind, claimed_at, claim_request_id)
    values (v_uid, 'complete_registration', now(), p_request_id)
    on conflict (user_id, kind) do nothing
    returning conversion_event_claims.event_id into v_event_id;

    if v_event_id is not null then
      return query select v_event_id, true;
      return;
    end if;
  end if;

  -- Já reivindicado (ou lead sem elegibilidade).
  select c.event_id, c.claim_request_id, c.claimed_at
    into v_event_id, v_request, v_claimed
    from public.conversion_event_claims c
   where c.user_id = v_uid
     and c.kind = p_kind;

  if v_claimed is not null then
    return query select v_event_id, (v_request = p_request_id);
  end if;
end;
$$;

comment on function public.claim_conversion_event(text, uuid) is
  'NUB-RD-85: reivindica uma vez o evento de conversão do usuário autenticado. '
  'should_emit=true só para o pedido que reivindicou (retry com o mesmo p_request_id repete).';

revoke all on function public.claim_conversion_event(text, uuid) from public, anon;
grant execute on function public.claim_conversion_event(text, uuid) to authenticated;
