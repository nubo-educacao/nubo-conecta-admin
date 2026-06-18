const { createClient } = require("@supabase/supabase-js");

const supabase = createClient(
  process.env.VITE_SUPABASE_URL,
  process.env.VITE_SUPABASE_ANON_KEY
);

async function main() {
  // Check if partners_click has data
  const { data: clickCount, error: err1 } = await supabase
    .from("partners_click")
    .select("*", { count: "exact" });
  
  console.log("Total clicks in partners_click:", clickCount?.length || 0);
  
  if (clickCount && clickCount.length > 0) {
    console.log("\nFirst 5 clicks:");
    console.log(clickCount.slice(0, 5));
  }

  // Check distinct partner_ids
  const { data: partnerIds } = await supabase
    .from("partners_click")
    .select("partner_id")
    .limit(1);
  
  console.log("\nSample partner_id from partners_click:", partnerIds?.[0]);

  // Check partner_opportunities
  const { data: partners } = await supabase
    .from("partner_opportunities")
    .select("id, name")
    .limit(3);
  
  console.log("\nSample partner_opportunities:");
  console.log(partners);
}

main().catch(console.error);
