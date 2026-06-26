#!/usr/bin/env node
/**
 * Backfill eligibility results and map form answers to user profiles.
 * Maps form answers from student_applications.answers to:
 * 1. student_applications.eligibility_results
 * 2. user_profiles columns using mapping_source
 * 3. user_preferences json using mapping_source
 */

import { createClient } from "@supabase/supabase-js";
import * as fs from "fs";
import * as path from "path";

// Load .env
const envPath = path.join(process.cwd(), ".env");
const envContent = fs.readFileSync(envPath, "utf-8");
const envLines = envContent.split("\n");

let supabaseUrl = null;
let supabaseKey = null;

envLines.forEach(line => {
  const trimmed = line.trim();
  if (trimmed.startsWith("VITE_SUPABASE_URL=")) {
    supabaseUrl = trimmed.split("=")[1].trim().replace(/^["']|["']$/g, "");
  }
  if (trimmed.startsWith("VITE_SUPABASE_PUBLISHABLE_KEY=")) {
    supabaseKey = trimmed.split("=")[1].trim().replace(/^["']|["']$/g, "");
  }
});

if (!supabaseUrl || !supabaseKey) {
  console.error("❌ Error: Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY in .env");
  console.error("   Found URL:", supabaseUrl ? "✓" : "✗");
  console.error("   Found KEY:", supabaseKey ? "✓" : "✗");
  process.exit(1);
}

const supabase = createClient(supabaseUrl, supabaseKey);

async function backfill() {
  console.log("🔄 Starting backfill...\n");

  let processed = 0;
  let errors = 0;

  try {
    // Get all submitted/redirected applications (both uppercase and lowercase variants)
    const { data: applications, error: appError } = await supabase
      .from("student_applications")
      .select("id, user_id, partner_id, answers, status")
      .or("status.eq.SUBMITTED,status.eq.redirected,status.eq.submitted");

    if (appError) {
      console.error("Query error:", appError);
      throw appError;
    }

    if (!applications || applications.length === 0) {
      console.log("❌ No applications found. Available statuses:");
      const { data: statusData } = await supabase
        .from("student_applications")
        .select("status")
        .limit(100);
      const statuses = [...new Set(statusData?.map(a => a.status) || [])];
      console.log(statuses);
      return;
    }

    console.log(`📊 Found ${applications.length} submitted applications\n`);

    for (const app of applications) {
      try {
        const appId = app.id;
        const userId = app.user_id;
        const partnerId = app.partner_id;
        const answers = app.answers || {};

        // Get partner forms
        const { data: forms, error: formsError } = await supabase
          .from("partner_forms")
          .select("field_name, mapping_source, is_criterion, criterion_rule, question_text")
          .eq("partner_id", partnerId);

        if (formsError) throw formsError;

        const eligibilityResults = [];
        const profileUpdates = {};
        const prefUpdates = {};

        // Process each form field
        for (const form of forms || []) {
          const fieldName = form.field_name;
          const mappingSource = form.mapping_source;
          const userAnswer = answers[fieldName];

          if (userAnswer === null || userAnswer === undefined) continue;

          // Map to user_profiles
          if (mappingSource?.startsWith("user_profiles.")) {
            const columnName = mappingSource.split(".")[1];
            profileUpdates[columnName] = userAnswer;
          }

          // Map to user_preferences
          if (mappingSource?.startsWith("user_preferences.")) {
            const jsonKey = mappingSource.split(".")[1];
            prefUpdates[jsonKey] = userAnswer;
          }

          // Calculate eligibility
          if (form.is_criterion && form.criterion_rule) {
            const met = userAnswer !== null && userAnswer !== undefined;
            eligibilityResults.push({
              question_text: form.question_text,
              met,
              user_answer: String(userAnswer)
            });
          }
        }

        // Update student_applications
        if (eligibilityResults.length > 0) {
          const { error: updateError } = await supabase
            .from("student_applications")
            .update({ eligibility_results: eligibilityResults })
            .eq("id", appId);

          if (updateError) throw updateError;
        }

        // Update user_profiles
        if (Object.keys(profileUpdates).length > 0 || eligibilityResults.length > 0) {
          const updates = { ...profileUpdates };
          if (eligibilityResults.length > 0) {
            updates.eligibility_results = eligibilityResults;
          }

          const { error: profileError } = await supabase
            .from("user_profiles")
            .update(updates)
            .eq("id", userId);

          if (profileError) throw profileError;
        }

        // Update user_preferences
        if (Object.keys(prefUpdates).length > 0) {
          const { data: existingPrefs } = await supabase
            .from("user_preferences")
            .select("preferences")
            .eq("user_id", userId)
            .maybeSingle();

          const mergedPrefs = {
            ...(existingPrefs?.preferences || {}),
            ...prefUpdates
          };

          const { error: prefError } = await supabase
            .from("user_preferences")
            .upsert({ user_id: userId, preferences: mergedPrefs });

          if (prefError) throw prefError;
        }

        processed++;
        if (processed % 50 === 0) {
          console.log(`✓ Processed ${processed} applications...`);
        }

      } catch (e) {
        errors++;
        console.error(`❌ Error processing application ${app.id}:`, e.message);
      }
    }

    console.log(`\n✅ Backfill completed!`);
    console.log(`   • Processed: ${processed}`);
    console.log(`   • Errors: ${errors}`);
    console.log(`   • Success: ${errors === 0 ? "Yes" : "No"}`);

  } catch (e) {
    console.error("❌ Fatal error:", e.message);
    process.exit(1);
  }
}

backfill();
