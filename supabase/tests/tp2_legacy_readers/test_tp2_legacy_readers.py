"""Leitores legados de tracking (TP-2 / NUB-RD-77b).

1. get_admin_funnel_users() deixa de ler external_redirect_clicks: a contagem de
   redirects por usuário vem de engagement_events (redirect de parceiro,
   SUM(event_count)), mantendo assinatura, guard, search_path e ACL.
2. scripts/tp2_reconciliation.sql reconhece os cliques live da Sprint 9.1
   (source = 'click:<surface>') além do literal legado 'card'.

Roda contra o banco DEV real, dentro de uma transação que SEMPRE faz rollback.
Produção é recusada.

    pip install pytest psycopg2-binary
    pytest supabase/tests/tp2_legacy_readers -v

A conexão vem de SUPABASE_DB_URL (ambiente ou .env da raiz do repo).
"""
import json
import os
import re
import uuid
from pathlib import Path
from urllib.parse import urlsplit

import psycopg2
import psycopg2.errors
import pytest

ROOT = Path(__file__).resolve().parents[3]
MIGRATION = ROOT / "supabase/migrations/20261020180000_tp2_admin_funnel_users_engagement_redirects.sql"
RECONCILIATION = ROOT / "scripts/tp2_reconciliation.sql"
DEV_REF = "yfgciamhzjvarwgzosto"

FUNNEL_USERS = "public.get_admin_funnel_users()"


def _db_url():
    url = os.environ.get("SUPABASE_DB_URL")
    env_file = ROOT / ".env"
    if not url and env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            if line.startswith("SUPABASE_DB_URL="):
                url = line.split("=", 1)[1].strip().strip('"').strip("'")
    if not url:
        pytest.skip("SUPABASE_DB_URL ausente")
    parts = urlsplit(url)
    if DEV_REF not in f"{parts.username}@{parts.hostname}":
        raise RuntimeError("Somente o projeto DEV é permitido")
    return url


@pytest.fixture
def q():
    conn = psycopg2.connect(_db_url(), connect_timeout=15)
    try:
        cur = conn.cursor()
        cur.execute("SET LOCAL statement_timeout = '30s'")
        yield cur
    finally:
        conn.rollback()
        conn.close()


def _apply_migration(cur):
    cur.execute(MIGRATION.read_text(encoding="utf-8"))


def _claims(cur, claims):
    cur.execute("SELECT set_config('request.jwt.claims', %s, true)", (json.dumps(claims),))


def _can(cur, role, sig):
    cur.execute("SELECT has_function_privilege(%s, %s, 'EXECUTE')", (role, sig))
    return cur.fetchone()[0]


def _function_shape(cur):
    cur.execute(
        """
        SELECT pg_get_function_result(p.oid), p.prosecdef, p.proconfig, p.proacl::text
        FROM pg_proc p WHERE p.oid = %s::regprocedure
        """,
        (FUNNEL_USERS,),
    )
    return cur.fetchone()


def _funnel_user(cur):
    cur.execute("SELECT user_id FROM public.vw_admin_user_funnel ORDER BY user_id LIMIT 1")
    row = cur.fetchone()
    if row is None:
        pytest.skip("DEV sem usuários em vw_admin_user_funnel")
    return row[0]


def _insert_event(cur, *, event_type, user_id, entity_id, source, event_count=1, destination_url=None):
    cur.execute(
        """
        INSERT INTO public.engagement_events
          (event_id, event_type, entity_type, entity_id, user_id, source, event_count, destination_url)
        VALUES (%s, %s, 'partner_opportunity', %s, %s, %s, %s, %s)
        """,
        (f"test-77b:{uuid.uuid4()}", event_type, entity_id, user_id, source, event_count, destination_url),
    )


def _funnel_redirect_total(cur):
    _claims(cur, {"role": "service_role"})
    cur.execute("SELECT COALESCE(SUM(external_redirect_clicks), 0) FROM public.get_admin_funnel_users()")
    return cur.fetchone()[0]


def _expected_redirect_total(cur):
    cur.execute(
        """
        SELECT COALESCE(SUM(e.event_count), 0)
        FROM public.engagement_events e
        JOIN public.vw_admin_user_funnel v ON v.user_id = e.user_id
        WHERE e.event_type = 'redirect' AND e.entity_type = 'partner_opportunity'
        """
    )
    return cur.fetchone()[0]


# ── get_admin_funnel_users ──────────────────────────────────────────────────


def test_definicao_nao_le_tabela_legada(q):
    _apply_migration(q)
    q.execute("SELECT prosrc FROM pg_proc WHERE oid = %s::regprocedure", (FUNNEL_USERS,))
    body = q.fetchone()[0]
    assert not re.search(r"\bfrom\s+(public\.)?external_redirect_clicks\b", body, re.I)
    assert re.search(r"\bfrom\s+public\.engagement_events\b", body, re.I)


def test_contagem_vem_de_engagement_events(q):
    user_id = _funnel_user(q)
    partner = str(uuid.uuid4())
    # Só existe na fonte nova: a leitura legada não o enxerga.
    _insert_event(q, event_type="redirect", user_id=user_id, entity_id=partner,
                  source="partner_application", event_count=3,
                  destination_url="https://example.invalid/77b")
    # Clique em card não é redirect e não pode entrar na coluna.
    _insert_event(q, event_type="card_click", user_id=user_id, entity_id=partner,
                  source="click:test_77b", event_count=5)
    _apply_migration(q)
    assert _funnel_redirect_total(q) == _expected_redirect_total(q)


def test_assinatura_guard_search_path_e_acl_preservados(q):
    before = _function_shape(q)
    _apply_migration(q)
    after = _function_shape(q)
    assert after == before
    result, secdef, config, _acl = after
    assert "external_redirect_clicks integer" in result
    assert secdef is True
    assert "search_path=public, pg_temp" in config
    assert not _can(q, "anon", FUNNEL_USERS)
    assert not _can(q, "public", FUNNEL_USERS)
    assert _can(q, "authenticated", FUNNEL_USERS)
    assert _can(q, "service_role", FUNNEL_USERS)


def test_autenticado_sem_permissao_e_recusado(q):
    _apply_migration(q)
    q.execute("SAVEPOINT plain_user")
    q.execute("SET LOCAL ROLE authenticated")
    _claims(q, {"role": "authenticated", "sub": str(uuid.uuid4())})
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        q.execute("SELECT * FROM public.get_admin_funnel_users()")
    q.execute("ROLLBACK TO SAVEPOINT plain_user")


def test_migration_e_idempotente(q):
    _apply_migration(q)
    _apply_migration(q)
    assert _funnel_redirect_total(q) == _expected_redirect_total(q)


# ── scripts/tp2_reconciliation.sql ──────────────────────────────────────────


def _reconciliation_statements():
    lines = [
        line for line in RECONCILIATION.read_text(encoding="utf-8").splitlines()
        if not line.lstrip().startswith("--")
    ]
    statements = [s.strip() for s in "\n".join(lines).split(";")]
    return [s for s in statements if re.match(r"(?is)^(select|with)\b", s)]


def _pair_comparison(cur):
    (statement,) = [s for s in _reconciliation_statements() if "AS comparison" in s]
    cur.execute(statement)
    return {row[0]: row[1] for row in cur.fetchall()}


def _new_legacy_pair(cur):
    """Usuário e parceiro sem linha em partners_click. O parceiro vem da tabela
    que a FK de partners_click referencia (DEV: partners; PROD: partner_opportunities)."""
    cur.execute(
        """
        SELECT confrelid::regclass::text FROM pg_constraint
        WHERE conrelid = 'public.partners_click'::regclass AND conname = 'partners_click_partner_id_fkey'
        """
    )
    target = cur.fetchone()[0]
    cur.execute(f"SELECT id FROM {target} ORDER BY id LIMIT 1")
    partner = cur.fetchone()[0]
    cur.execute(
        """
        SELECT u.id FROM auth.users u
        WHERE NOT EXISTS (SELECT 1 FROM public.partners_click pc WHERE pc.user_id = u.id AND pc.partner_id = %s)
        ORDER BY u.id LIMIT 1
        """,
        (partner,),
    )
    return cur.fetchone()[0], partner


@pytest.mark.parametrize("source", ["card", "click:home_para_voce"])
def test_reconciliacao_casa_clique_live_com_incremento_legado(q, source):
    before = _pair_comparison(q)
    user_id, partner = _new_legacy_pair(q)
    q.execute(
        "INSERT INTO public.partners_click (user_id, partner_id, clicks) VALUES (%s, %s, 1)",
        (user_id, partner),
    )
    q.execute(
        """
        INSERT INTO public.engagement_events
          (event_id, event_type, entity_type, entity_id, user_id, source, event_count)
        VALUES (%s, 'card_click', 'partner_opportunity', %s, %s, %s, 1)
        """,
        (f"card_click:{user_id}:{partner}:2026-10-20T18:00", partner, user_id, source),
    )
    after = _pair_comparison(q)
    assert after.get("equal", 0) == before.get("equal", 0) + 1
    assert after.get("legacy_greater", 0) == before.get("legacy_greater", 0)
    assert after.get("new_greater", 0) == before.get("new_greater", 0)
