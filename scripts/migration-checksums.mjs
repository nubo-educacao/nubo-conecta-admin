import { createHash } from "node:crypto";
import { readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const migrationsDirectory = path.join(root, "supabase", "migrations");
const manifestPath = path.join(root, "supabase", "migrations.sha256");
const baselinePath = path.join(root, "backup_prod_schema.sql");
const rolesPath = path.join(root, "supabase", "roles.sql");
const migrationNamePattern = /^(\d{14})_[a-z0-9][a-z0-9_]*\.sql$/;

const migrationFiles = (await readdir(migrationsDirectory, { withFileTypes: true }))
  .filter((entry) => entry.isFile() && entry.name.endsWith(".sql"))
  .map((entry) => entry.name)
  .sort();

const invalidNames = migrationFiles.filter(
  (fileName) => !migrationNamePattern.test(fileName),
);

if (invalidNames.length > 0) {
  throw new Error(
    `Migration names must follow YYYYMMDDHHMMSS_description.sql:\n${invalidNames.join("\n")}`,
  );
}

const timestamps = new Map();
for (const fileName of migrationFiles) {
  const timestamp = migrationNamePattern.exec(fileName)[1];
  const existing = timestamps.get(timestamp);
  if (existing) {
    throw new Error(
      `Duplicate migration timestamp ${timestamp}: ${existing}, ${fileName}`,
    );
  }
  timestamps.set(timestamp, fileName);
}

const schemaFiles = [
  { absolutePath: baselinePath, relativePath: "backup_prod_schema.sql" },
  { absolutePath: rolesPath, relativePath: "supabase/roles.sql" },
  ...migrationFiles.map((fileName) => ({
    absolutePath: path.join(migrationsDirectory, fileName),
    relativePath: `supabase/migrations/${fileName}`,
  })),
];

const entries = await Promise.all(
  schemaFiles.map(async ({ absolutePath, relativePath }) => {
    const contents = await readFile(absolutePath, "utf8");
    const normalizedContents = contents.replace(/\r\n/g, "\n");
    const checksum = createHash("sha256")
      .update(normalizedContents, "utf8")
      .digest("hex");
    return `${checksum}  ${relativePath}`;
  }),
);

const expectedManifest = `${entries.join("\n")}\n`;

if (process.argv.includes("--write")) {
  await writeFile(manifestPath, expectedManifest, "utf8");
  console.log(
    `Updated ${path.relative(root, manifestPath)} (${migrationFiles.length} migrations and two legacy artifacts).`,
  );
  process.exit(0);
}

let currentManifest;
try {
  currentManifest = (await readFile(manifestPath, "utf8")).replace(/\r\n/g, "\n");
} catch (error) {
  if (error.code === "ENOENT") {
    throw new Error(
      "Migration checksum manifest is missing. Run pnpm db:migrations:checksum.",
    );
  }
  throw error;
}

if (currentManifest !== expectedManifest) {
  throw new Error(
    "Migration history changed or the checksum manifest is stale. " +
      "Never edit an applied migration; add a new migration instead. " +
      "For a legitimate new file, run pnpm db:migrations:checksum and commit the manifest.",
  );
}

console.log(
  `Verified ${migrationFiles.length} immutable migrations, the production baseline, and legacy roles.`,
);
