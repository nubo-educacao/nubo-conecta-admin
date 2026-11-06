import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(
  new URL("./supabase-dev-migrations-plan.mjs", import.meta.url),
);
const passwordMarker = "planner-test-password";
const projectRef = "yfgciamhzjvarwgzosto";
const directHost = `db.${projectRef}.supabase.co`;
const poolerHost = "aws-1-sa-east-1.pooler.supabase.com";
const directUser = "dev_migrations_reader";
const poolerUser = `${directUser}.${projectRef}`;

function databaseUrl({ host, user, port = 5432, database = "postgres" }) {
  return `postgresql://${encodeURIComponent(user)}:${encodeURIComponent(passwordMarker)}@${host}:${port}/${database}`;
}

function validateTarget(url) {
  const result = spawnSync(process.execPath, [scriptPath, "validate-target"], {
    encoding: "utf8",
    env: {
      ...process.env,
      SUPABASE_DEV_READONLY_DB_URL: url,
      SUPABASE_DEV_CA_CERT: "",
    },
  });
  const output = `${result.stdout}${result.stderr}`;
  assert.equal(output.includes(passwordMarker), false);
  assert.equal(output.includes(url), false);
  return {
    status: result.status,
    output,
  };
}

test("accepts the fixed DEV direct endpoint and direct-role username", () => {
  const result = validateTarget(
    databaseUrl({ host: directHost, user: directUser }),
  );

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /trusted Supabase DEV CA certificate is not configured/,
  );
  assert.doesNotMatch(result.output, /\[destination\]/);
});

test("accepts the fixed DEV Session pooler and project-qualified username", () => {
  const result = validateTarget(
    databaseUrl({ host: poolerHost, user: poolerUser }),
  );

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /trusted Supabase DEV CA certificate is not configured/,
  );
  assert.doesNotMatch(result.output, /\[destination\]/);
});

const rejectedUrls = [
  [
    "another Supabase project direct hostname",
    databaseUrl({
      host: "db.otherproject.supabase.co",
      user: directUser,
    }),
  ],
  [
    "another project identifier in the Session pooler username",
    databaseUrl({
      host: poolerHost,
      user: "dev_migrations_reader.otherproject",
    }),
  ],
  [
    "unexpected username on the direct endpoint",
    databaseUrl({ host: directHost, user: poolerUser }),
  ],
  [
    "unqualified username on the Session pooler",
    databaseUrl({ host: poolerHost, user: directUser }),
  ],
  [
    "unapproved pooler hostname",
    databaseUrl({
      host: "aws-1-us-east-1.pooler.supabase.com",
      user: poolerUser,
    }),
  ],
  [
    "unexpected port",
    databaseUrl({
      host: poolerHost,
      user: poolerUser,
      port: 6543,
    }),
  ],
  [
    "unexpected database",
    databaseUrl({
      host: poolerHost,
      user: poolerUser,
      database: "template1",
    }),
  ],
  [
    "URL query parameters",
    `${databaseUrl({ host: poolerHost, user: poolerUser })}?sslmode=disable`,
  ],
  [
    "URL fragment",
    `${databaseUrl({ host: poolerHost, user: poolerUser })}#other`,
  ],
];

for (const [description, url] of rejectedUrls) {
  test(`rejects ${description}`, () => {
    const result = validateTarget(url);

    assert.notEqual(result.status, 0);
    assert.match(result.output, /\[destination\]/);
    assert.doesNotMatch(
      result.output,
      /trusted Supabase DEV CA certificate is not configured/,
    );
  });
}
