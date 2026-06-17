#!/usr/bin/env node
/**
 * Script to backfill eligibility results and user profile mappings
 * for applications submitted before the new logic was implemented.
 *
 * Usage: node scripts/backfill-eligibility.mjs
 */

import { createClient } from "@supabase/supabase-js";
import * as fs from "fs";
import * as path from "path";
import * as readline from "readline";

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
});

function prompt(question) {
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      resolve(answer);
    });
  });
}

// Load .env file
const envPath = path.join(process.cwd(), ".env");
const envContent = fs.readFileSync(envPath, "utf-8");
const envLines = envContent.split("\n");

let supabaseUrl = null;
let supabaseKey = null;

// Parse .env file
envLines.forEach(line => {
  if (line.startsWith("VITE_SUPABASE_URL=")) {
    supabaseUrl = line.split("=")[1].trim().replace(/^["']|["']$/g, "");
  }
  if (line.startsWith("VITE_SUPABASE_ANON_KEY=") || line.startsWith("SUPABASE_SERVICE_ROLE_KEY=")) {
    supabaseKey = line.split("=")[1].trim().replace(/^["']|["']$/g, "");
  }
});

// Override with env vars if provided
supabaseUrl = process.env.VITE_SUPABASE_URL || supabaseUrl;
supabaseKey = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.VITE_SUPABASE_ANON_KEY || supabaseKey;

if (!supabaseUrl) {
  console.error("❌ Error: Missing VITE_SUPABASE_URL");
  process.exit(1);
}

if (!supabaseKey) {
  console.log("⚠️  Supabase authentication key not found in .env");
  console.log("   You can get it from: https://app.supabase.com/project/aifzkybxhmefbirujvdg/api?lang=javascript");
  console.log("   Use the 'anon' key or 'service_role' key\n");
  supabaseKey = await prompt("Enter your Supabase key: ");

  if (!supabaseKey) {
    console.error("❌ Error: No key provided");
    rl.close();
    process.exit(1);
  }
}

rl.close();

const supabase = createClient(supabaseUrl, supabaseKey);

async function backfillEligibility() {
  console.log("🔄 Starting eligibility and profile mapping backfill...\n");

  try {
    const { data, error } = await supabase.rpc("backfill_eligibility_and_mappings");

    if (error) {
      console.error("❌ RPC Error:", error.message);
      process.exit(1);
    }

    if (!data || data.length === 0) {
      console.error("❌ No data returned from RPC");
      process.exit(1);
    }

    const result = data[0];
    console.log("✅ Backfill completed successfully!\n");
    console.log(`📊 Results:`);
    console.log(`   • Processed: ${result.processed_count} applications`);
    console.log(`   • Errors: ${result.error_count} applications`);
    console.log(`   • Success: ${result.success ? "Yes" : "No"}\n`);

    if (result.error_count > 0) {
      console.warn(`⚠️  ${result.error_count} applications had errors. Check the database logs for details.`);
    } else {
      console.log("🎉 All applications processed without errors!");
    }

  } catch (err) {
    console.error("❌ Unexpected error:", err.message);
    process.exit(1);
  }
}

backfillEligibility();
