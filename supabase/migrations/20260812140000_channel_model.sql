-- TP-7 7B — modelo de canal (campanha / canal / link)
-- Card fbc7273e · governance doc f74d1cd9 §3.1 e §3.2.4
--
-- ══ POR QUE ═════════════════════════════════════════════════════════════════
-- Metadado de canal não tem casa no banco. Hoje mora em três lugares errados:
-- uma coluna de texto (user_profiles.referral_source), uma string hardcoded num
-- modal e um <script> no layout. O resultado auditado em produção:
--
--   · 82 registros em `influencers`, dos quais só 30 são pessoas divulgando
--   · o maior gerador de cadastros é disparo de CRM, cadastrado como "influencer"
--   · a campanha do Insper existe espalhada em 10 links e ninguém consegue somá-la
--   · não existe dado de clique: há numerador (cadastro) e não há denominador
--
-- ══ A HIERARQUIA ════════════════════════════════════════════════════════════
--   CAMPANHA (o objetivo)      "Bolsa Insper 2026"
--     └── CANAL (quem divulga)  Dudinha / disparo WhatsApp / Instituto Sol
--           └── LINK (a peça)   Instagram / TikTok / QR da feira
--
-- Campanha e canal são ORTOGONAIS: a mesma campanha usa vários canais e o mesmo
-- canal participa de várias campanhas. Instituto Sol é parceiro E aparece dentro
-- da campanha do Insper — é o caso que prova a ortogonalidade.
--
-- Dois níveis de agrupamento bastam. Não criar um terceiro até doer.

-- ── Vocabulários fechados (§3.2.4) ──────────────────────────────────────────
-- Lookup em vez de CHECK: o marketing precisa ler a lista na tela do construtor,
-- e CHECK constraint não é consultável de forma útil pelo front.

CREATE TABLE IF NOT EXISTS public.channel_mediums (
  slug        TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  description TEXT
);

INSERT INTO public.channel_mediums (slug, name, description) VALUES
  ('crm',        'CRM',        'Disparo para base própria (WhatsApp, e-mail)'),
  ('influencer', 'Influencer', 'Pessoa divulgando (com audiência ou indicação individual)'),
  ('owned',      'Próprio',    'Canal próprio do Nubo (banner no app, live, perfil orgânico, grupo)'),
  ('partner',    'Parceiro',   'Instituição parceira divulgando'),
  ('paid',       'Mídia paga', 'Mídia paga'),
  ('event',      'Evento',     'Presencial (feira, flyer, QR)')
ON CONFLICT (slug) DO NOTHING;

-- Decidido: NÃO criar 'ambassador' por enquanto. Divulgador individual entra
-- como 'influencer'. Reavaliar se o programa de indicação ganhar volume próprio.

CREATE TABLE IF NOT EXISTS public.platforms (
  slug     TEXT PRIMARY KEY,
  name     TEXT NOT NULL,
  category TEXT NOT NULL
);

-- A categoria ("Canal", no vocabulário do marketing) é DERIVADA da plataforma,
-- nunca digitada. Instagram é sempre Social. É o que elimina o campo em branco
-- que hoje aparece como "Não definido".
INSERT INTO public.platforms (slug, name, category) VALUES
  ('instagram',        'Instagram',        'Social'),
  ('tiktok',           'TikTok',           'Social'),
  ('youtube',          'YouTube',          'Social'),
  ('facebook',         'Facebook',         'Social'),
  ('linkedin',         'LinkedIn',         'Social'),
  ('kwai',             'Kwai',             'Social'),
  ('whatsapp',         'WhatsApp',         'Mensageria'),
  ('telegram',         'Telegram',         'Mensageria'),
  ('email',            'E-mail',           'Email'),
  ('google',           'Google',           'Busca'),
  ('site-parceiro',    'Site do parceiro', 'Site'),
  ('blog-nubo',        'Blog Nubo',        'Site'),
  ('app-nubo',         'App Nubo',         'App'),
  ('evento-presencial','Evento presencial','Evento'),
  ('flyer',            'Flyer',            'Offline'),
  ('ooh',              'Mídia OOH',        'Offline'),
  ('qrcode',           'QR Code',          'Offline')
ON CONFLICT (slug) DO NOTHING;

-- ── Entidades ───────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.campaigns (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       TEXT NOT NULL UNIQUE,
  name       TEXT NOT NULL,
  objective  TEXT,
  starts_at  DATE,
  ends_at    DATE,
  owner      TEXT,
  active     BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT campaigns_slug_format CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

COMMENT ON TABLE public.campaigns IS
'Objetivo de negócio agrupador. É tabela e não campo de texto para que agrupar vire JOIN em vez de LIKE ''insper%'' — typo fica impossível e a campanha ganha período, dono e objetivo. TP-7 7B.';

CREATE TABLE IF NOT EXISTS public.channels (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug        TEXT NOT NULL UNIQUE,
  name        TEXT NOT NULL,
  type        TEXT NOT NULL REFERENCES public.channel_mediums(slug),
  owner_name  TEXT,
  active      BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  archived_at TIMESTAMPTZ,
  CONSTRAINT channels_slug_format CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

COMMENT ON TABLE public.channels IS
'Quem divulga (o ator). Substitui a tabela influencers, que virou depósito: dos 82 registros só 30 eram pessoas. `type` é o utm_medium e vem de lista fechada. TP-7 7B.';

CREATE TABLE IF NOT EXISTS public.channel_links (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id      UUID REFERENCES public.campaigns(id),
  channel_id       UUID NOT NULL REFERENCES public.channels(id),
  platform_id      TEXT REFERENCES public.platforms(slug),

  -- O que vai na URL: /r/<code>. UNIQUE porque é a chave de resolução.
  code             TEXT NOT NULL UNIQUE,

  -- Apelido humano. O código é para a máquina; isto é para o marketing achar
  -- o link na biblioteca sem decorar slug.
  nickname         TEXT,

  destination_path TEXT NOT NULL DEFAULT '/',

  -- Congelados na criação, não derivados na leitura: se a campanha for
  -- renomeada, os links já distribuídos continuam significando o que
  -- significavam quando saíram. Renomear campanha não pode reescrever história.
  utm_source       TEXT,
  utm_medium       TEXT,
  utm_campaign     TEXT,
  utm_content      TEXT,
  utm_term         TEXT,

  created_by       UUID,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  archived_at      TIMESTAMPTZ,

  -- Slugificação é automática e invisível no construtor, mas a garantia é aqui:
  -- validação só no formulário não impede insert por outro caminho.
  --
  -- A regra é negativa, não positiva, e isso é deliberado. Uma allowlist de
  -- [A-Za-z0-9._/+-] rejeita `fundação1Bi`, que existe em produção e tem links
  -- distribuídos — e um code legado NÃO pode ser reescrito, senão o link que
  -- está no bolso de alguém deixa de atribuir. O que precisa ser barrado é o
  -- que quebra a URL: espaço e os metacaracteres de query/fragmento.
  CONSTRAINT channel_links_code_format
    CHECK (code !~ '[\s#?&%]' AND length(code) BETWEEN 1 AND 100)
);

COMMENT ON TABLE public.channel_links IS
'A peça distribuída. `code` é o que aparece em /r/<code>. As colunas utm_* são congeladas na criação de propósito: renomear a campanha não pode reescrever o significado de links já distribuídos. TP-7 7B/7D.';

CREATE INDEX IF NOT EXISTS channel_links_campaign_idx ON public.channel_links (campaign_id);
CREATE INDEX IF NOT EXISTS channel_links_channel_idx  ON public.channel_links (channel_id);

CREATE TABLE IF NOT EXISTS public.user_attribution (
  user_id             UUID PRIMARY KEY,
  first_touch_link_id UUID REFERENCES public.channel_links(id),
  last_touch_link_id  UUID REFERENCES public.channel_links(id),
  first_touch_at      TIMESTAMPTZ,
  last_touch_at       TIMESTAMPTZ,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Tabela própria, não colunas em user_profiles — que já tem 34 colunas.
-- First E last touch: o middleware atual sobrescreve o cookie de referral e
-- por isso perde o primeiro toque, que é justamente o que responde "quem
-- trouxe essa pessoa".
COMMENT ON TABLE public.user_attribution IS
'Atribuição de origem por usuário, first e last touch. Separada de user_profiles de propósito. TP-7 7B.';

CREATE TABLE IF NOT EXISTS public.conversions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID NOT NULL,
  channel_link_id UUID REFERENCES public.channel_links(id),
  event_type      TEXT NOT NULL,
  value           NUMERIC,
  occurred_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS conversions_link_idx ON public.conversions (channel_link_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS conversions_user_idx ON public.conversions (user_id, occurred_at DESC);

-- ── Fecha o contrato do TP-2 ────────────────────────────────────────────────
-- engagement_events.channel_link_id nasceu sem FK porque channel_links ainda
-- não existia. Agora existe.
ALTER TABLE public.engagement_events
  DROP CONSTRAINT IF EXISTS engagement_events_channel_link_fk;
ALTER TABLE public.engagement_events
  ADD CONSTRAINT engagement_events_channel_link_fk
  FOREIGN KEY (channel_link_id) REFERENCES public.channel_links(id);

-- ── Backfill dos 82 registros (§3.1.1, classificação validada) ──────────────
--
-- Cada registro legado vira um CANAL e um LINK que preserva o `code`. Preservar
-- o code é obrigatório: existem links de ?ref= distribuídos por aí, e quebrá-los
-- perderia a atribuição de quem chegar depois.

CREATE TEMP TABLE _legacy_class (code TEXT PRIMARY KEY, medium TEXT, archive BOOLEAN DEFAULT false);

-- CRM (10) — o maior gerador de cadastros do Nubo, hoje disfarçado de influencer
INSERT INTO _legacy_class (code, medium) VALUES
  ('pontesol09','crm'), ('pontesol_16_03','crm'), ('disparonubo','crm'),
  ('insper21/07','crm'), ('estudar09','crm'), ('estudar16_03','crm'),
  ('disparo16_03','crm'), ('disparo24/03','crm'), ('sisu+','crm'),
  ('estudantes-nubo','crm');

-- owned (4)
INSERT INTO _legacy_class (code, medium) VALUES
  ('boasvindas-nubo','owned'), ('insperapp','owned'), ('orginsper','owned'), ('grupo','owned');

-- paid (3)
INSERT INTO _legacy_class (code, medium) VALUES
  ('insperads','paid'), ('Facebook','paid'), ('midiaooh','paid');

-- partner (11)
INSERT INTO _legacy_class (code, medium) VALUES
  ('institutoponte','partner'), ('institutosol','partner'), ('ponte','partner'),
  ('sol','partner'), ('arco','partner'), ('projete','partner'),
  ('confluenciasrn','partner'), ('faceufmg','partner'), ('pr_recife','partner'),
  ('fundação1Bi','partner'), ('coemb','partner');

-- event (2)
INSERT INTO _legacy_class (code, medium) VALUES
  ('ribeirao','event'), ('insper','event');

-- Arquivados (22): são os códigos de unidade da USP (EACH, ECA, FAU, FEA,
-- FFLCH, Poli…), cadastrados para uma ação que não usa mais este mecanismo.
-- Arquivar e não deletar: se algum link ainda circular, o clique continua
-- resolvendo e a atribuição não se perde.
INSERT INTO _legacy_class (code, medium, archive)
SELECT code, 'owned', true FROM public.influencers WHERE code LIKE '%INT';

-- Todo o resto (30) é gente divulgando.
INSERT INTO _legacy_class (code, medium)
SELECT i.code, 'influencer' FROM public.influencers i
 WHERE NOT EXISTS (SELECT 1 FROM _legacy_class c WHERE c.code = i.code);

INSERT INTO public.channels (slug, name, type, active, created_at, archived_at)
SELECT
  -- Slug determinístico a partir do code: minúsculo, sem acento, sem separador
  -- solto. O code original continua vivo em channel_links.code.
  regexp_replace(
    regexp_replace(lower(translate(i.code, 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
                                           'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')),
                  '[^a-z0-9]+', '-', 'g'),
    '(^-+|-+$)', '', 'g'),
  i.name,
  c.medium,
  NOT c.archive,
  i.created_at,
  CASE WHEN c.archive THEN now() ELSE NULL END
FROM public.influencers i
JOIN _legacy_class c ON c.code = i.code
ON CONFLICT (slug) DO NOTHING;

INSERT INTO public.channel_links (channel_id, code, nickname, utm_medium, utm_content, created_at, archived_at)
SELECT
  ch.id,
  i.code,                       -- preservado: links distribuídos continuam válidos
  i.name,
  c.medium,
  ch.slug,                      -- utm_content = identificador do divulgador
  i.created_at,
  CASE WHEN c.archive THEN now() ELSE NULL END
FROM public.influencers i
JOIN _legacy_class c ON c.code = i.code
JOIN public.channels ch
  ON ch.slug = regexp_replace(
       regexp_replace(lower(translate(i.code, 'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
                                              'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC')),
                     '[^a-z0-9]+', '-', 'g'),
       '(^-+|-+$)', '', 'g')
ON CONFLICT (code) DO NOTHING;

-- ── Campanhas retroativas (§3.1.2) ──────────────────────────────────────────
-- Números conferidos em prod: Ponte e Sol soma 218 cadastros e Estudar soma 37,
-- idênticos ao documento. A do Insper é a que mais importa: 10 links que hoje
-- ninguém consegue somar.
INSERT INTO public.campaigns (slug, name, objective) VALUES
  ('bolsa-insper-2026', 'Bolsa Insper 2026', 'Inscrições no processo seletivo do Insper'),
  ('ponte-e-sol',       'Ponte e Sol',       'Disparo para base dos institutos Ponte e Sol'),
  ('estudar',           'Estudar',           'Disparo para base do Estudar'),
  ('sisu-mais',         'SISU+',             'Disparo SISU+'),
  ('base-cloudinha',    'Base Cloudinha',    'Ativação da base da Cloudinha')
ON CONFLICT (slug) DO NOTHING;

UPDATE public.channel_links l SET campaign_id = c.id, utm_campaign = c.slug
FROM public.campaigns c
WHERE c.slug = 'bolsa-insper-2026'
  AND l.code IN ('disparonubo','insper21/07','insperads','insperapp','grupo',
                 'projete','arco','orginsper','sol','insper');

UPDATE public.channel_links l SET campaign_id = c.id, utm_campaign = c.slug
FROM public.campaigns c
WHERE c.slug = 'ponte-e-sol' AND l.code IN ('pontesol09','pontesol_16_03');

UPDATE public.channel_links l SET campaign_id = c.id, utm_campaign = c.slug
FROM public.campaigns c
WHERE c.slug = 'estudar' AND l.code IN ('estudar09','estudar16_03');

UPDATE public.channel_links l SET campaign_id = c.id, utm_campaign = c.slug
FROM public.campaigns c WHERE c.slug = 'sisu-mais' AND l.code = 'sisu+';

UPDATE public.channel_links l SET campaign_id = c.id, utm_campaign = c.slug
FROM public.campaigns c WHERE c.slug = 'base-cloudinha' AND l.code = 'estudantes-nubo';

-- ── Atribuição retroativa ───────────────────────────────────────────────────
-- referral_source já apontava para o code. Vira first touch — é o único toque
-- que conhecemos destes usuários, e tratá-lo como último seria inventar dado.
INSERT INTO public.user_attribution (user_id, first_touch_link_id, first_touch_at, last_touch_at, last_touch_link_id)
SELECT p.id, l.id, p.created_at, p.created_at, l.id
FROM public.user_profiles p
JOIN public.channel_links l ON l.code = p.referral_source
WHERE p.referral_source IS NOT NULL
ON CONFLICT (user_id) DO NOTHING;

-- ── Reconciliação ───────────────────────────────────────────────────────────
DO $reconcile$
DECLARE
  v_influencers INT; v_channels INT; v_links INT; v_attr INT; v_referral INT;
  v_sem_classe INT;
BEGIN
  SELECT count(*) INTO v_influencers FROM public.influencers;
  SELECT count(*) INTO v_channels FROM public.channels;
  SELECT count(*) INTO v_links FROM public.channel_links;
  SELECT count(*) INTO v_attr FROM public.user_attribution;
  SELECT count(*) INTO v_referral FROM public.user_profiles WHERE referral_source IS NOT NULL;
  SELECT count(*) INTO v_sem_classe FROM public.channels WHERE type IS NULL;

  IF v_links <> v_influencers THEN
    RAISE EXCEPTION 'backfill de canal não reconciliou: % registros legados viraram % links',
      v_influencers, v_links;
  END IF;

  IF v_sem_classe > 0 THEN
    RAISE EXCEPTION '% canais sem medium — classificação incompleta', v_sem_classe;
  END IF;

  RAISE NOTICE 'canal OK — % legados -> % canais / % links; atribuição: % de % perfis com referral',
    v_influencers, v_channels, v_links, v_attr, v_referral;
END
$reconcile$;

-- ── RLS ─────────────────────────────────────────────────────────────────────
-- Leitura de canal/campanha é backoffice. channel_links precisa ser legível
-- pela resolução de /r/<code>, que roda server-side sem sessão — por isso a
-- resolução será RPC SECURITY DEFINER, e não policy pública.
ALTER TABLE public.campaigns        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channels         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.channel_links    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_attribution ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversions      ENABLE ROW LEVEL SECURITY;

DO $pol$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['campaigns','channels','channel_links','user_attribution','conversions'] LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I_admin_all ON public.%I', t, t);
    EXECUTE format(
      'CREATE POLICY %I_admin_all ON public.%I FOR ALL USING (public.is_backoffice_admin()) WITH CHECK (public.is_backoffice_admin())',
      t, t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM PUBLIC', t);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
      EXECUTE format('GRANT SELECT, INSERT, UPDATE ON TABLE public.%I TO authenticated', t);
    END IF;
  END LOOP;

  -- Lookups são vocabulário público: o construtor de links precisa listá-los.
  FOREACH t IN ARRAY ARRAY['platforms','channel_mediums'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN
      EXECUTE format('GRANT SELECT ON TABLE public.%I TO authenticated', t);
    END IF;
  END LOOP;
END
$pol$;
