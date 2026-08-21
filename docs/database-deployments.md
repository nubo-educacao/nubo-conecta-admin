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

## Recovery

If a production migration fails, Vercel promotion remains blocked. Fix the database with a new forward-only migration, update the checksum manifest, and merge the correction. Do not rewrite the failed migration after it may have run partially.
