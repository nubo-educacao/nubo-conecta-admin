const { Client } = require('pg');

async function checkView() {
  const client = new Client({
    connectionString: 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
  });
  
  await client.connect();
  
  try {
    const res = await client.query(`
      SELECT column_name 
      FROM information_schema.columns 
      WHERE table_name = 'v_unified_institutions';
    `);
    console.log("Columns in v_unified_institutions:");
    res.rows.forEach(r => console.log(r.column_name));

    // Reload PostgREST schema cache just in case
    await client.query(`NOTIFY pgrst, 'reload schema';`);
    console.log("Notified PostgREST to reload schema.");
  } catch (e) {
    console.error("Error:", e);
  } finally {
    await client.end();
  }
}

checkView();
