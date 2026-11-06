import { createHash, X509Certificate } from "node:crypto";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const DEV_PROJECT_REF = "yfgciamhzjvarwgzosto";
const DIRECT_DATABASE_HOST = `db.${DEV_PROJECT_REF}.supabase.co`;
const SESSION_POOLER_HOST = "aws-1-sa-east-1.pooler.supabase.com";
const DIRECT_DATABASE_USER = "dev_migrations_reader";
const SESSION_POOLER_USER = `${DIRECT_DATABASE_USER}.${DEV_PROJECT_REF}`;
const migrationNamePattern = /^(\d{14})_[a-z0-9][a-z0-9_]*\.sql$/;
const ledgerQuery =
  "SELECT COALESCE(json_agg(json_build_object('version', version::text) ORDER BY version), '[]'::json)::text FROM supabase_migrations.schema_migrations";

class SafeDiagnosticError extends Error {
  constructor(category, message) {
    super(message);
    this.category = category;
  }
}

function optionsFrom(args) {
  const options = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || !value || options[key.slice(2)]) {
      throw new Error("Invalid or duplicate command-line option.");
    }
    options[key.slice(2)] = value;
  }
  return options;
}

function sha256(contents) {
  return createHash("sha256").update(contents).digest("hex");
}

async function fileDigest(filePath) {
  const contents = (await readFile(filePath, "utf8")).replace(/\r\n/g, "\n");
  return sha256(contents);
}

async function migrationInventory(candidateDirectory) {
  const migrationsDirectory = path.join(
    candidateDirectory,
    "supabase",
    "migrations",
  );
  const fileNames = (
    await readdir(migrationsDirectory, { withFileTypes: true })
  )
    .filter((entry) => entry.isFile() && entry.name.endsWith(".sql"))
    .map((entry) => entry.name)
    .sort();

  const timestamps = new Set();
  const migrations = [];
  for (const fileName of fileNames) {
    const match = migrationNamePattern.exec(fileName);
    if (!match) {
      throw new Error(`Invalid migration filename: ${fileName}`);
    }
    if (timestamps.has(match[1])) {
      throw new Error(`Duplicate migration timestamp: ${match[1]}`);
    }
    timestamps.add(match[1]);
    migrations.push({
      version: match[1],
      file: fileName,
      sha256: await fileDigest(path.join(migrationsDirectory, fileName)),
    });
  }
  return migrations;
}

async function verifyManifest(candidateDirectory, migrations) {
  const baselinePath = path.join(
    candidateDirectory,
    "supabase",
    "production_baseline.sql",
  );
  const rolesPath = path.join(candidateDirectory, "supabase", "roles.sql");
  const entries = [
    `${await fileDigest(baselinePath)}  supabase/production_baseline.sql`,
    `${await fileDigest(rolesPath)}  supabase/roles.sql`,
  ];
  for (const migration of migrations) {
    entries.push(`${migration.sha256}  supabase/migrations/${migration.file}`);
  }

  const manifest = (
    await readFile(
      path.join(candidateDirectory, "supabase", "migrations.sha256"),
      "utf8",
    )
  ).replace(/\r\n/g, "\n");
  const expectedManifest = `${entries.join("\n")}\n`;
  if (manifest !== expectedManifest) {
    throw new Error(
      "Candidate migrations.sha256 does not match the candidate files.",
    );
  }
  return sha256(manifest);
}

async function inventory(options) {
  const candidateDirectory = path.resolve(required(options, "candidate"));
  const candidateSha = required(options, "sha").toLowerCase();
  const prNumber = required(options, "pr-number");
  if (!/^[0-9a-f]{40}$/.test(candidateSha) || !/^\d+$/.test(prNumber)) {
    throw new Error("Invalid candidate SHA or PR number.");
  }

  const checkedOutSha = execFileSync(
    "git",
    ["-C", candidateDirectory, "rev-parse", "HEAD"],
    {
      encoding: "utf8",
    },
  )
    .trim()
    .toLowerCase();
  if (checkedOutSha !== candidateSha) {
    throw new Error("Candidate checkout does not match the requested SHA.");
  }

  const migrations = await migrationInventory(candidateDirectory);
  const manifestSha256 = await verifyManifest(candidateDirectory, migrations);
  const prFiles = JSON.parse(
    await readFile(required(options, "pr-files"), "utf8"),
  );
  if (!Array.isArray(prFiles)) {
    throw new Error("GitHub PR file list is not an array.");
  }

  const changedMigrations = prFiles.filter((file) =>
    file.filename?.startsWith("supabase/migrations/"),
  );
  if (changedMigrations.length === 0) {
    throw new Error("The PR does not add a migration.");
  }
  if (
    changedMigrations.some(
      (file) =>
        file.status !== "added" ||
        !/^supabase\/migrations\/[^/]+\.sql$/.test(file.filename),
    )
  ) {
    throw new Error(
      "Migrations in the PR must be new SQL files; existing migrations are immutable.",
    );
  }

  const addedNames = changedMigrations
    .map((file) => file.filename.slice("supabase/migrations/".length))
    .sort();
  const candidateNames = migrations
    .filter((migration) => addedNames.includes(migration.file))
    .map((migration) => migration.file)
    .sort();
  if (candidateNames.length !== addedNames.length) {
    throw new Error(
      "A migration added by the PR is missing from the candidate tree.",
    );
  }

  const output = {
    projectRef: DEV_PROJECT_REF,
    candidateSha,
    prNumber,
    manifestSha256,
    migrations,
    prMigrations: candidateNames,
  };
  await writeFile(
    required(options, "output"),
    `${JSON.stringify(output, null, 2)}\n`,
    "utf8",
  );
}

function required(options, key) {
  const value = options[key];
  if (!value) {
    throw new Error(`Missing required option: --${key}`);
  }
  return value;
}

function databaseConnection() {
  const connectionString = process.env.SUPABASE_DEV_READONLY_DB_URL;
  if (!connectionString) {
    throw new SafeDiagnosticError(
      "configuration",
      "DEV read-only database credentials are not configured.",
    );
  }
  let target;
  try {
    target = new URL(connectionString);
  } catch {
    throw new SafeDiagnosticError(
      "configuration",
      "DEV database connection configuration is malformed.",
    );
  }
  let username;
  let password;
  try {
    username = decodeURIComponent(target.username);
    password = decodeURIComponent(target.password);
  } catch {
    throw new SafeDiagnosticError(
      "configuration",
      "DEV database credentials are not valid URL-encoded values.",
    );
  }
  if (
    !["postgres:", "postgresql:"].includes(target.protocol) ||
    ![DIRECT_DATABASE_HOST, SESSION_POOLER_HOST].includes(target.hostname) ||
    target.port !== "5432" ||
    target.pathname !== "/postgres" ||
    (target.hostname === DIRECT_DATABASE_HOST &&
      username !== DIRECT_DATABASE_USER) ||
    (target.hostname === SESSION_POOLER_HOST &&
      username !== SESSION_POOLER_USER) ||
    !password ||
    target.search ||
    target.hash ||
    connectionString.includes("?") ||
    connectionString.includes("#") ||
    /[\0\r\n]/.test(username) ||
    /[\0\r\n]/.test(password)
  ) {
    throw new SafeDiagnosticError(
      "destination",
      "Connection must use an allowed DEV endpoint, its expected database role, and no query or fragment parameters.",
    );
  }
  return {
    host: target.hostname,
    connectionString: target,
  };
}

function certificateBundle() {
  const contents = process.env.SUPABASE_DEV_CA_CERT;
  if (!contents) {
    throw new SafeDiagnosticError(
      "configuration",
      "The trusted Supabase DEV CA certificate is not configured.",
    );
  }
  const certificates = contents.match(
    /-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g,
  );
  if (
    !certificates?.length ||
    contents
      .replace(
        /-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/g,
        "",
      )
      .trim()
  ) {
    throw new SafeDiagnosticError(
      "tls",
      "The configured DEV CA bundle is not a valid PEM certificate bundle.",
    );
  }
  try {
    for (const certificate of certificates) {
      if (!new X509Certificate(certificate).ca) {
        throw new Error("not a CA");
      }
    }
  } catch {
    throw new SafeDiagnosticError(
      "tls",
      "The configured DEV CA bundle is invalid or does not contain CA certificates.",
    );
  }
  return {
    pem: `${certificates.join("\n")}\n`,
    fingerprints: certificates.map(
      (certificate) => new X509Certificate(certificate).fingerprint256,
    ),
  };
}

function validateTarget() {
  const connection = databaseConnection();
  const ca = certificateBundle();
  console.log(`Confirmed fixed DEV database host: ${connection.host}`);
  console.log(
    `TLS mode: verify-full (${ca.fingerprints.length} trusted CA certificate(s)).`,
  );
}

async function runLedgerQuery(options) {
  const connection = databaseConnection();
  const ca = certificateBundle();
  const caFile = path.resolve(required(options, "ca-file"));
  const outputFile = required(options, "output");
  await writeFile(caFile, ca.pem, { encoding: "utf8", mode: 0o600 });
  await chmod(caFile, 0o600);

  const secureConnectionString = new URL(connection.connectionString);
  secureConnectionString.searchParams.set("sslmode", "verify-full");
  secureConnectionString.searchParams.set("sslrootcert", caFile);
  const environment = Object.fromEntries(
    Object.entries(process.env).filter(
      ([key]) =>
        !key.toUpperCase().startsWith("PG") &&
        !key.toUpperCase().startsWith("SUPABASE_"),
    ),
  );

  const result = spawnSync(
    "supabase",
    [
      "--agent=no",
      "db",
      "query",
      "--db-url",
      secureConnectionString.toString(),
      "--output",
      "json",
      ledgerQuery,
    ],
    {
      env: environment,
      encoding: "utf8",
      maxBuffer: 1024 * 1024,
      timeout: 30_000,
    },
  );
  if (result.error || result.status !== 0) {
    throw classifyDatabaseError(result.error, result.stderr, result.signal);
  }

  let rows;
  try {
    rows = JSON.parse(result.stdout.trim());
  } catch {
    throw new SafeDiagnosticError(
      "unexpected_format",
      "The database client returned an unexpected ledger format.",
    );
  }
  if (
    !Array.isArray(rows) ||
    rows.some(
      (row) =>
        !row ||
        typeof row.version !== "string" ||
        !/^\d{14}$/.test(row.version),
    )
  ) {
    throw new SafeDiagnosticError(
      "unexpected_format",
      "The database client returned an unexpected ledger format.",
    );
  }
  await writeFile(
    outputFile,
    `${JSON.stringify({ rows, caFingerprints: ca.fingerprints }, null, 2)}\n`,
    "utf8",
  );
}

function classifyDatabaseError(spawnError, stderr = "", signal) {
  if (spawnError?.code === "ENOENT") {
    return new SafeDiagnosticError(
      "client_unavailable",
      "The Supabase CLI is unavailable on the runner.",
    );
  }
  if (
    spawnError?.code === "ETIMEDOUT" ||
    signal === "SIGTERM" ||
    /timeout/i.test(stderr)
  ) {
    return new SafeDiagnosticError(
      "connectivity",
      "The DEV database connection timed out.",
    );
  }
  if (/certificate|ssl|tls|verify-full|root certificate/i.test(stderr)) {
    return new SafeDiagnosticError(
      "tls",
      "TLS certificate or hostname verification failed.",
    );
  }
  if (
    /password authentication failed|authentication failed|no password supplied|SASL/i.test(
      stderr,
    )
  ) {
    return new SafeDiagnosticError(
      "authentication",
      "DEV database authentication failed.",
    );
  }
  if (/permission denied|insufficient privilege|not authorized/i.test(stderr)) {
    return new SafeDiagnosticError(
      "permission",
      "The read-only database role cannot read the migration ledger.",
    );
  }
  if (
    /failed to parse connection string|invalid connection|invalid sslmode|invalid port/i.test(
      stderr,
    )
  ) {
    return new SafeDiagnosticError(
      "configuration",
      "The direct database connection configuration was rejected.",
    );
  }
  if (
    /could not connect|connection refused|no route to host|could not translate host name|network is unreachable|Name or service not known/i.test(
      stderr,
    )
  ) {
    return new SafeDiagnosticError(
      "connectivity",
      "The DEV database could not be reached.",
    );
  }
  return new SafeDiagnosticError(
    "query_failed",
    "The read-only ledger query failed; raw database diagnostics were suppressed.",
  );
}

async function confirmPullRequest(options) {
  const reportPath = path.resolve(required(options, "report"));
  const prNumber = Number(required(options, "pr-number"));
  const candidateSha = required(options, "sha").toLowerCase();
  const repository = process.env.GITHUB_REPOSITORY;
  let pr;
  try {
    pr = JSON.parse(await readFile(required(options, "pr-json"), "utf8"));
  } catch {
    await failReport(
      reportPath,
      "GitHub PR metadata could not be revalidated.",
    );
    throw new SafeDiagnosticError(
      "pr_metadata",
      "GitHub PR metadata could not be revalidated.",
    );
  }
  if (
    !repository ||
    !Number.isSafeInteger(prNumber) ||
    pr.number !== prNumber ||
    pr.state !== "open" ||
    pr.head?.sha !== candidateSha ||
    pr.head?.repo?.full_name !== repository ||
    pr.head?.ref === "main" ||
    pr.base?.ref !== "main"
  ) {
    await failReport(
      reportPath,
      "The PR is no longer open with the analyzed SHA and approved repository/target.",
    );
    throw new SafeDiagnosticError(
      "pr_changed",
      "Final PR freshness check failed; the report is not valid for the current PR head.",
    );
  }
  const report = await readFile(reportPath, "utf8");
  const marker = "\n## Candidate migrations and checksums";
  if (!report.includes(marker)) {
    throw new SafeDiagnosticError(
      "report_format",
      "The planning report could not be finalized.",
    );
  }
  await writeFile(
    reportPath,
    report.replace(
      marker,
      "\n- Final PR verification: PASS; current open PR head matches the analyzed SHA.\n\n## Candidate migrations and checksums",
    ),
    "utf8",
  );
}

async function failReport(reportPath, reason) {
  let report = await readFile(reportPath, "utf8");
  report = report.replace("- Preflight: **PASS**", "- Preflight: **FAIL**");
  report += `\n- Final PR verification: FAIL - ${reason}\n`;
  await writeFile(reportPath, report, "utf8");
}

function parseRemoteVersions(remoteContents) {
  const result = JSON.parse(remoteContents);
  if (!result || !Array.isArray(result.rows)) {
    throw new Error("Database client output did not contain a rows array.");
  }
  const versions = result.rows.map((row) => row.version);
  if (
    versions.some(
      (version) => typeof version !== "string" || !/^\d{14}$/.test(version),
    )
  ) {
    throw new Error("The remote migration ledger contains an invalid version.");
  }
  if (new Set(versions).size !== versions.length) {
    throw new Error("The remote migration ledger contains duplicate versions.");
  }
  return new Set(versions);
}

async function createPlan(options) {
  const plan = JSON.parse(
    await readFile(required(options, "inventory"), "utf8"),
  );
  if (plan.projectRef !== DEV_PROJECT_REF) {
    throw new Error(
      "Inventory project ref does not match the fixed DEV project.",
    );
  }
  const remote = JSON.parse(
    await readFile(required(options, "remote"), "utf8"),
  );
  const remoteVersions = parseRemoteVersions(JSON.stringify(remote));
  const caFingerprints = Array.isArray(remote.caFingerprints)
    ? remote.caFingerprints
    : [];
  const localByVersion = new Map(
    plan.migrations.map((migration) => [migration.version, migration]),
  );
  const prVersions = new Set(
    plan.migrations
      .filter((migration) => plan.prMigrations.includes(migration.file))
      .map((migration) => migration.version),
  );

  const remoteOnly = [...remoteVersions]
    .filter((version) => !localByVersion.has(version))
    .sort();
  const pending = plan.migrations.filter(
    (migration) => !remoteVersions.has(migration.version),
  );
  const unrelatedPending = pending.filter(
    (migration) => !prVersions.has(migration.version),
  );
  const prAlreadyRegistered = [...prVersions]
    .filter((version) => remoteVersions.has(version))
    .sort();
  const pendingPr = pending.filter((migration) =>
    prVersions.has(migration.version),
  );
  const passed =
    remoteOnly.length === 0 &&
    unrelatedPending.length === 0 &&
    prAlreadyRegistered.length === 0 &&
    pendingPr.length > 0;

  const lines = [
    "# Supabase DEV migration plan",
    "",
    `- Project ref: \`${DEV_PROJECT_REF}\``,
    "- Target confirmation: host and project-specific user matched an allowlisted DEV endpoint; `verify-full` certificate and hostname validation succeeded.",
    ...caFingerprints.map(
      (fingerprint, index) =>
        `- Trusted CA certificate ${index + 1} SHA-256: \`${fingerprint}\``,
    ),
    `- Candidate SHA: \`${plan.candidateSha}\``,
    `- Candidate PR: #${plan.prNumber} (same repository, open, targeting \`main\`)`,
    `- Manifest SHA-256: \`${plan.manifestSha256}\``,
    `- Preflight: **${passed ? "PASS" : "FAIL"}**`,
    "",
    "## Candidate migrations and checksums",
    "",
  ];
  for (const migration of plan.migrations.filter((item) =>
    prVersions.has(item.version),
  )) {
    lines.push(
      `- \`${migration.version}\` - \`${migration.file}\` - SHA-256 \`${migration.sha256}\``,
    );
  }

  lines.push("", "## Local migrations pending in DEV", "");

  if (pending.length === 0) {
    lines.push("- None.");
  } else {
    for (const migration of pending) {
      const category = prVersions.has(migration.version)
        ? "candidate PR"
        : "unrelated to candidate PR";
      lines.push(
        `- \`${migration.version}\` - \`${migration.file}\` - ${category} - SHA-256 \`${migration.sha256}\``,
      );
    }
  }

  lines.push("", "## Remote versions without a local migration", "");
  lines.push(
    remoteOnly.length
      ? remoteOnly.map((version) => `- \`${version}\``).join("\n")
      : "- None.",
  );
  lines.push("", "## Candidate migrations already registered remotely", "");
  lines.push(
    prAlreadyRegistered.length
      ? prAlreadyRegistered.map((version) => `- \`${version}\``).join("\n")
      : "- None.",
  );
  lines.push("", "## Preflight findings", "");
  const findings = [];
  if (remoteOnly.length) {
    findings.push(
      "Remote ledger versions have no corresponding local migration file.",
    );
  }
  if (unrelatedPending.length) {
    findings.push(
      "Pending migrations outside the candidate PR would be included in a whole-repository plan.",
    );
  }
  if (prAlreadyRegistered.length) {
    findings.push(
      "One or more candidate PR migrations are already registered remotely.",
    );
  }
  if (!pendingPr.length) {
    findings.push("No candidate PR migration is pending in DEV.");
  }
  lines.push(
    findings.length
      ? findings.map((finding) => `- FAIL: ${finding}`).join("\n")
      : "- No divergences detected.",
  );
  lines.push(
    "",
    "No migration application was performed. This report does not verify remote SQL definitions against local file contents.",
    "",
  );

  await writeFile(required(options, "output"), `${lines.join("\n")}\n`, "utf8");
  if (!passed) {
    throw new Error("Migration plan preflight failed; see report.");
  }
}

async function main() {
  const [phase, ...args] = process.argv.slice(2);
  if (phase === "validate-target") {
    validateTarget();
    return;
  }
  const options = optionsFrom(args);
  if (phase === "run-ledger-query") {
    await runLedgerQuery(options);
    return;
  }
  if (phase === "inventory") {
    await inventory(options);
    return;
  }
  if (phase === "plan") {
    await createPlan(options);
    return;
  }
  if (phase === "confirm-pr") {
    await confirmPullRequest(options);
    return;
  }
  if (phase === "fail-report") {
    await failReport(
      path.resolve(required(options, "report")),
      required(options, "reason"),
    );
    return;
  }
  throw new Error("Expected phase: inventory, validate-target, or plan.");
}

main().catch((error) => {
  if (error instanceof SafeDiagnosticError) {
    console.error(`[${error.category}] ${error.message}`);
  } else {
    console.error(error.message);
  }
  process.exitCode = 1;
});
