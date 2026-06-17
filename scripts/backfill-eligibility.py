#!/usr/bin/env python3
"""
Backfill eligibility results and map form answers to user profiles.
This script processes all submitted/redirected applications and:
1. Calculates eligibility_results from form answers
2. Maps answers to user_profiles columns using mapping_source
3. Maps answers to user_preferences json using mapping_source
"""

import os
import json
from supabase import create_client, Client

# Initialize Supabase
supabase_url = os.getenv("VITE_SUPABASE_URL")
supabase_key = os.getenv("SUPABASE_SERVICE_ROLE_KEY") or os.getenv("VITE_SUPABASE_ANON_KEY")

if not supabase_url or not supabase_key:
    print("❌ Error: Missing VITE_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY")
    exit(1)

supabase: Client = create_client(supabase_url, supabase_key)

def backfill():
    """Backfill eligibility and profile mappings for all submitted applications."""
    print("🔄 Starting backfill...\n")

    processed = 0
    errors = 0

    try:
        # 1. Get all submitted/redirected applications
        result = supabase.table("student_applications").select(
            "id, user_id, partner_id, answers, status"
        ).in_("status", ["SUBMITTED", "redirected"]).execute()

        applications = result.data
        print(f"📊 Found {len(applications)} submitted applications\n")

        for app in applications:
            try:
                app_id = app["id"]
                user_id = app["user_id"]
                partner_id = app["partner_id"]
                answers = app["answers"] or {}

                # 2. Get partner forms for this partner
                forms_result = supabase.table("partner_forms").select(
                    "field_name, mapping_source, is_criterion, criterion_rule, question_text"
                ).eq("partner_id", partner_id).execute()

                forms = forms_result.data or []

                eligibility_results = []
                profile_updates = {}
                pref_updates = {}

                # 3. Process each form field
                for form in forms:
                    field_name = form["field_name"]
                    mapping_source = form["mapping_source"]
                    user_answer = answers.get(field_name)

                    if user_answer is None:
                        continue

                    # Map to user_profiles
                    if mapping_source and mapping_source.startswith("user_profiles."):
                        column_name = mapping_source.split(".")[-1]
                        profile_updates[column_name] = user_answer

                    # Map to user_preferences
                    if mapping_source and mapping_source.startswith("user_preferences."):
                        json_key = mapping_source.split(".")[-1]
                        pref_updates[json_key] = user_answer

                    # Calculate eligibility
                    if form.get("is_criterion") and form.get("criterion_rule"):
                        met = user_answer is not None
                        eligibility_results.append({
                            "question_text": form.get("question_text"),
                            "met": met,
                            "user_answer": str(user_answer)
                        })

                # 4. Update student_applications with eligibility_results
                if eligibility_results:
                    supabase.table("student_applications").update({
                        "eligibility_results": eligibility_results
                    }).eq("id", app_id).execute()

                # 5. Update user_profiles with mapped data
                if profile_updates or eligibility_results:
                    updates = {**profile_updates}
                    if eligibility_results:
                        updates["eligibility_results"] = eligibility_results

                    supabase.table("user_profiles").update(updates).eq("id", user_id).execute()

                # 6. Update user_preferences with mapped data
                if pref_updates:
                    # Get existing preferences
                    prefs_result = supabase.table("user_preferences").select("preferences").eq("user_id", user_id).maybeSingle().execute()
                    existing_prefs = prefs_result.data.get("preferences", {}) if prefs_result.data else {}

                    # Merge with new preferences
                    merged_prefs = {**existing_prefs, **pref_updates}

                    # Upsert
                    supabase.table("user_preferences").upsert({
                        "user_id": user_id,
                        "preferences": merged_prefs
                    }).execute()

                processed += 1
                if processed % 50 == 0:
                    print(f"✓ Processed {processed} applications...")

            except Exception as e:
                errors += 1
                print(f"❌ Error processing application {app['id']}: {str(e)}")

        print(f"\n✅ Backfill completed!")
        print(f"   • Processed: {processed}")
        print(f"   • Errors: {errors}")
        print(f"   • Success: {errors == 0}")

    except Exception as e:
        print(f"❌ Fatal error: {str(e)}")
        exit(1)

if __name__ == "__main__":
    backfill()
