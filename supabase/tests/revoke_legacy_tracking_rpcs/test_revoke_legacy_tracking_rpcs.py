"""Revogação de EXECUTE anônimo nas RPCs legadas de tracking.

Roda contra o banco DEV real (roles e default privileges do Supabase), dentro de
uma transação que SEMPRE faz rollback. Produção é recusada.

    pip install pytest psycopg2-binary
    pytest supabase/tests/revoke_legacy_tracking_rpcs -v

A conexão vem de SUPABASE_DB_URL (ambiente ou .env da raiz do repo).
"""
import os
from pathlib import Path
from urllib.parse import urlsplit

import psycopg2
import psycopg2.errors
import pytest

ROOT = Path(__file__).resolve().parents[3]
MIGRATION = ROOT / "supabase/migrations/20261015204010_revoke_legacy_tracking_rpcs_anon.sql"
DEV_REF = "yfgciamhzjvarwgzosto"

STUDENT_DETAILS = "public.get_student_details_v2(uuid)"
FUNNEL_USERS = "public.get_admin_funnel_users()"
REDIRECT_USERS = "public.get_partner_redirect_users(uuid)"


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
        _reproduce_production_acl(cur)
        yield cur
    finally:
        conn.rollback()
        conn.close()


def _reproduce_production_acl(cur):
    """ACL conferida em produção em 2026-10-15: PUBLIC, anon, authenticated e
    service_role com EXECUTE nas três. get_student_details_v2 não existe no DEV:
    um stub com a mesma assinatura recebe as mesmas permissões."""
    cur.execute(
        """
        DO $$ BEGIN
          IF to_regprocedure('public.get_student_details_v2(uuid)') IS NULL THEN
            CREATE FUNCTION public.get_student_details_v2(p_user_id uuid)
              RETURNS integer LANGUAGE sql SECURITY DEFINER AS 'SELECT 1';
          END IF;
        END $$;
        """
    )
    for sig in (STUDENT_DETAILS, FUNNEL_USERS, REDIRECT_USERS):
        cur.execute(f"GRANT EXECUTE ON FUNCTION {sig} TO PUBLIC, anon, authenticated, service_role")


def _can(cur, role, sig):
    cur.execute("SELECT has_function_privilege(%s, %s, 'EXECUTE')", (role, sig))
    return cur.fetchone()[0]


def _apply_migration(cur):
    cur.execute(MIGRATION.read_text(encoding="utf-8"))


def test_baseline_reproduz_exposicao_de_producao(q):
    for sig in (STUDENT_DETAILS, FUNNEL_USERS, REDIRECT_USERS):
        assert _can(q, "anon", sig), sig


def test_anon_perde_execute_nas_tres(q):
    _apply_migration(q)
    for sig in (STUDENT_DETAILS, FUNNEL_USERS, REDIRECT_USERS):
        assert not _can(q, "anon", sig), sig


def test_rpcs_em_uso_continuam_para_authenticated(q):
    _apply_migration(q)
    assert _can(q, "authenticated", FUNNEL_USERS)
    assert _can(q, "authenticated", REDIRECT_USERS)


def test_rpc_orfa_fica_restrita_ao_service_role(q):
    _apply_migration(q)
    assert not _can(q, "authenticated", STUDENT_DETAILS)
    for sig in (STUDENT_DETAILS, FUNNEL_USERS, REDIRECT_USERS):
        assert _can(q, "service_role", sig), sig


def test_chamada_anonima_e_recusada(q):
    _apply_migration(q)
    q.execute("SAVEPOINT anon_call")
    q.execute("SET LOCAL ROLE anon")
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        q.execute("SELECT * FROM public.get_admin_funnel_users()")
    q.execute("ROLLBACK TO SAVEPOINT anon_call")


def test_migration_e_idempotente(q):
    _apply_migration(q)
    _apply_migration(q)
    assert not _can(q, "anon", FUNNEL_USERS)


def test_migration_tolera_funcao_ausente(q):
    q.execute("DROP FUNCTION public.get_student_details_v2(uuid)")
    _apply_migration(q)
    assert not _can(q, "anon", FUNNEL_USERS)
