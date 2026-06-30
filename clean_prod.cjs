const { Client } = require('pg');

const client = new Client({
  connectionString: 'postgresql://postgres:SYK80OGPcr0C06xp@db.aifzkybxhmefbirujvdg.supabase.co:5432/postgres'
});

async function run() {
  try {
    await client.connect();
    console.log("Connected to PROD DB");

    const query = `
      UPDATE student_applications
      SET answers = answers 
          - 'id' - 'full_name' - 'email' - 'phone' - 'age' - 'cpf' - 'city' - 'state' 
          - 'street' - 'country' - 'zip_code' - 'education' - 'avatar_url' - 'birth_date' 
          - 'complement' - 'created_at' - 'updated_at' - 'isdependent' - 'neighborhood' 
          - 'relationship' - 'street_number' - 'workflow_data' - 'education_year' 
          - 'outside_brazil' - 'parent_user_id' - 'passport_phase' - 'active_workflow' 
          - 'is_nubo_student' - 'referral_source' - 'eligibility_results' 
          - 'current_dependent_id' - 'onboarding_completed' - 'furthest_passport_phase' 
          - 'active_application_target_id'
      WHERE answers IS NOT NULL;
    `;

    const res = await client.query(query);
    console.log(`Updated ${res.rowCount} rows.`);
  } catch (err) {
    console.error("Error executing query", err);
  } finally {
    await client.end();
  }
}

run();
