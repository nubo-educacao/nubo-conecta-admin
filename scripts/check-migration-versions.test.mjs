import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { validateMigrationVersions } from './check-migration-versions.mjs';

test('rejects the TP-1/TP-2 collision despite different migration names', () => {
  assert.throws(() => validateMigrationVersions([
    '20261009193000_command_center_opportunity_interest.sql',
    '20261009193000_tp2_residual_engagement_dashboards.sql',
  ]), /Duplicate migration version 20261009193000/);
});

test('accepts the consolidated migration order after renaming the unapplied TP-1 migration', () => {
  assert.equal(validateMigrationVersions([
    '20261009193000_tp2_residual_engagement_dashboards.sql',
    '20261009194500_tp2_portal_redirect_wrapper.sql',
    '20261009195500_tp2_guard_missing_role.sql',
    '20261009203000_command_center_opportunity_interest.sql',
  ]), 4);
});

test('ignores backup files but rejects unversioned SQL files', () => {
  assert.equal(validateMigrationVersions(['98_fix_user_profiles_rls.sql.bak']), 0);
  assert.throws(() => validateMigrationVersions(['manual.sql']), /Invalid migration filename/);
});
