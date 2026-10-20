import { readFileSync, writeFileSync, unlinkSync, readdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
const cli = (args) => {
  const options = {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 12 * 1024 * 1024,
  };
  const argv = ["--yes", "supabase@2.121.0", ...args];
  return process.platform === "win32"
    ? execFileSync(
        "cmd.exe",
        ["/d", "/s", "/c", "npx " + argv.join(" ")],
        options,
      )
    : execFileSync("npx", argv, options);
};
const ref = "yfgciamhzjvarwgzosto";
const read = (p) => readFileSync(p, "utf8");
const pending = [
  "20261019170042_demographics_quota_inferred.sql",
  "20261019171331_cc_attribution_sql_aggregates.sql",
  ...readdirSync("supabase/migrations")
    .filter((n) => /_tpd_/.test(n))
    .sort(),
];
const guard = read("supabase/tests/sprint91_contracts/dev_guard.sql");
const mode = process.argv[2] ?? "contracts";
const strip = (s) => s.replace(/^\s*(BEGIN|COMMIT)\s*;\s*$/gim, "");
let body = "BEGIN;\n" + guard + "\n";
body += `SELECT set_config('request.jwt.claims','{"role":"service_role"}',true);
SELECT set_config('request.jwt.claim.role','service_role',true);
CREATE TEMP TABLE tpd_legacy_before AS SELECT pg_get_functiondef('public.get_tp2_partner_funnel(uuid,integer)'::regprocedure) old_fn,pg_get_viewdef('public.vw_partner_funnel'::regclass) old_view, public.get_mec_engagement_dashboard(NULL,NULL) old_mec;
`;
for (const name of pending)
  body += "\n-- " + name + "\n" + strip(read("supabase/migrations/" + name));
body += "\n" + guard + "\n";
body += `DO $tpd$ DECLARE r jsonb; BEGIN
ASSERT (SELECT old_fn=pg_get_functiondef('public.get_tp2_partner_funnel(uuid,integer)'::regprocedure) AND old_view=pg_get_viewdef('public.vw_partner_funnel'::regclass) FROM tpd_legacy_before),'v1/view altered';
r:=public.get_mec_engagement_dashboard(NULL,NULL);
ASSERT (SELECT old_mec=jsonb_set(r,'{coverage}',(r->'coverage')-'redirect') FROM tpd_legacy_before),'MEC published fields altered';
END $tpd$;
`;
if (mode === "contracts") {
  body += "\n" + read("supabase/tests/sprint91_contracts/assert.sql");
  body += "\n" + read("supabase/tests/sprint91_contracts/cleanup.sql");
  body += "\nDO $$ BEGIN RAISE EXCEPTION 'TPD_ALL_PASS rollback-only'; END $$;";
} else if (mode === "ccaf") {
  body +=
    "\n" +
    read("supabase/tests/command_center_attribution_filters/fixture.sql");
  body +=
    "\n" +
    read("supabase/tests/command_center_attribution_filters/baseline.sql");
  body +=
    "\n" +
    read(
      "supabase/tests/command_center_attribution_filters/assert_aggregates.sql",
    );
  body +=
    "\n" + read("supabase/tests/command_center_attribution_filters/assert.sql");
} else if (mode === "s9") {
  body += "\n" + read("supabase/tests/sprint9_integration/assert.sql");
  body += "\nDO $$ BEGIN RAISE EXCEPTION 'S9_ALL_PASS rollback-only'; END $$;";
} else throw Error("unknown mode");
if (/^\s*(COMMIT|ROLLBACK|END\s+TRANSACTION)\s*;/im.test(body))
  throw Error("unexpected transaction terminator");
const file = ".tpd-rollback-" + mode + ".sql";
writeFileSync(file, body);
try {
  let output;
  try {
    output = cli([
      "db",
      "query",
      "--linked",
      "--project-ref",
      ref,
      "--file",
      file,
    ]);
  } catch (e) {
    output = String(e.stdout ?? "") + "\n" + String(e.stderr ?? "");
  }
  const success =
    mode === "contracts"
      ? "TPD_ALL_PASS"
      : mode === "ccaf"
        ? "CCAF_ALL_PASS"
        : "S9_ALL_PASS";
  if (
    !new RegExp("ERROR:\\s+P0001:\\s+" + success + "(?: |\\()").test(output)
  ) {
    console.error(output);
    process.exitCode = 1;
  } else
    console.log(
      success +
        " — PostgreSQL intentional abort confirmed; no changes persisted.",
    );
} finally {
  unlinkSync(file);
}
