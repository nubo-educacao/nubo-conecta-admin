DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'partner') THEN
    CREATE ROLE partner NOLOGIN;
  END IF;
END
$$;
