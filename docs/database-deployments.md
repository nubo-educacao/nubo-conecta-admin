# Database deployment gate

Production database migrations are applied by `.github/workflows/supabase-migrations.yml` before a Vercel production deployment is promoted.

## GitHub configuration

Configure the `Production` environment with:

- secret `SUPABASE_ACCESS_TOKEN`: a Supabase personal access token allowed to deploy the project;
- secret `SUPABASE_DB_PASSWORD`: the production project's database password;
- variable `SUPABASE_PROJECT_ID`: the production project reference.

The workflow never runs seeds in production. Because the original legacy database predates migration tracking, pull requests load the versioned `supabase/production_baseline.sql` baseline (captured through migration `20260814160000`), restore the legacy roles from `supabase/roles.sql`, and replay every forward migration after it on a clean local database. The baseline, roles, and all migration files are protected by the checksum manifest. Production checks the pending plan, applies only pending migration files, and then confirms that the remote database is synchronized.

## Vercel gate

In the Vercel project, open **Settings > Deployment Checks > Production**, add a GitHub check, and require `Supabase production migrations` before promotion. Keep the existing Git integration enabled so previews continue to work normally.

## Adding a migration

1. Create a forward-only file named `YYYYMMDDHHMMSS_description.sql` in `supabase/migrations`.
2. Run `pnpm db:migrations:checksum`.
3. Commit both the migration and `supabase/migrations.sha256`.
4. Open a pull request and wait for `Verify migration integrity` and `Replay migrations from zero`.

Never edit or delete an already applied migration. Add a corrective migration instead.

## Planning migrations in DEV

`.github/workflows/supabase-migrations-dev.yml` is a read-only planning workflow. It must be dispatched using the protected `main` ref and receives the full SHA of the head commit of one open PR from this repository to `main`. It checks out candidate files for inspection only; it does not run candidate scripts. The workflow has no migration-application command.

Before enabling it, configure the GitHub `Development` environment:

- Add required reviewers and restrict deployment branches to `main`.
- Protect `main` so only reviewed changes can modify the controller workflow and its planning script.
- Add the secret `SUPABASE_DEV_READONLY_DB_URL` for the DEV project `yfgciamhzjvarwgzosto`, with the username and password URL-encoded and no query or fragment parameters. The planner accepts either the direct endpoint `db.yfgciamhzjvarwgzosto.supabase.co:5432` with user `dev_migrations_reader`, or the Session pooler endpoint `aws-1-sa-east-1.pooler.supabase.com:5432` with user `dev_migrations_reader.yfgciamhzjvarwgzosto`; both must use database `postgres`. Do not use a Production secret or a Supabase management access token. The pooler hostname is shared across projects, so the exact project-qualified username is part of destination validation.
- Add the `Development` environment variable `SUPABASE_DEV_CA_CERT` with the PEM CA certificate bundle downloaded from that DEV project's **Database Settings > SSL Configuration**. Verify its fingerprint against the dashboard when configuring or rotating it.
- The database role in this URL must have only the required effective privileges: `CONNECT` on the database, `USAGE` on `supabase_migrations`, and `SELECT` on `supabase_migrations.schema_migrations`, with no inherited memberships or other effective migration, schema, or data-write privileges. The current `dev_migrations_reader` was found to inherit write privileges from `PUBLIC`; it is not approved for use until the DBA removes or otherwise eliminates those effective privileges and verifies the role. `default_transaction_read_only=on` does not replace this audit.
- Do not add a user-selectable project-ref variable. The workflow pins the DEV project and rejects any database URL whose host, role name, database, port, parameters, or TLS configuration do not match one of the two allowed endpoints. The pooler username format is configured from the Dashboard value but has not yet been verified by a real connection.

The workflow token is limited to repository contents and pull-request reads. The candidate must be the exact head SHA of one open same-repository PR targeting `main`; modified or removed migration files fail validation. A trusted script on the controller checkout verifies the candidate checksum manifest and hashes migration files. The pinned controller rechecks the PR state, repository, target branch, and head SHA immediately before finalizing a successful report.

Supabase CLI `2.98.2` supports direct `db query --db-url`; `--linked` would use the Management API and is not used. The pinned CLI parses the direct URL with `pgconn` 1.14.3. Its `sslmode=verify-full` path sets the TLS server name to the URL hostname, and its `sslrootcert` parameter loads the supplied CA bundle as the trust store. The trusted script rejects every query or fragment in the configured URL, writes the validated CA bundle to a permission-restricted temporary file, and appends only `sslmode=verify-full` and that CA file path to the connection URL passed to the CLI. The SQL is a fixed `SELECT`; candidate SQL is never executed.

The Supabase CLI requires the database URL as a command-line argument for this mode; no compatible environment-variable alternative was confirmed in the pinned CLI. This applies to both the direct endpoint and Session pooler. Consequently, the password-bearing URL can be visible in process arguments to other processes running as the same user. The workflow never prints it, captures CLI stderr and reports only sanitized failure categories, and does not put it in the report artifact. Use GitHub-hosted ephemeral runners, do not enable shell tracing or CLI debug output, and do not run untrusted concurrent processes on that runner.

The workflow suppresses raw PostgreSQL client errors and reports only sanitized categories (configuration, TLS, authentication, connectivity, permission, client unavailable, or unexpected query result). The CA contents and connection credentials are not included in the uploaded artifact. External Actions are pinned to full commit SHAs.

The preflight fails if the remote ledger has versions without local files, if the candidate migration is already registered remotely, or if any unrelated local migration is pending in DEV. Therefore a passing report means the candidate PR's new migrations are the only local pending migrations; it is not authorization to apply them. Any application workflow requires a separate reviewed implementation and explicit approval.

Dispatch from **Actions > Supabase DEV migration plan > Run workflow**, select `main` as the workflow ref, and provide the complete candidate commit SHA. Review the report artifact before taking any separate action.

## Recovery

If a production migration fails, Vercel promotion remains blocked. Fix the database with a new forward-only migration, update the checksum manifest, and merge the correction. Do not rewrite the failed migration after it may have run partially.
