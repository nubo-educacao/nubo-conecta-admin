import { readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

export function validateMigrationVersions(files) {
  const versions = new Map();
  const errors = [];
  for (const file of files.filter((name) => name.endsWith('.sql')).sort()) {
    const match = /^(\d{14})_.+\.sql$/.exec(file);
    if (!match) {
      errors.push(`Invalid migration filename: ${file}`);
      continue;
    }
    const previous = versions.get(match[1]);
    if (previous) errors.push(`Duplicate migration version ${match[1]}: ${previous}, ${file}`);
    else versions.set(match[1], file);
  }
  if (errors.length) throw new Error(errors.join('\n'));
  return versions.size;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const count = validateMigrationVersions(readdirSync(new URL('../supabase/migrations/', import.meta.url)));
    console.log(`PASS: ${count} migrations with unique 14-digit versions`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
