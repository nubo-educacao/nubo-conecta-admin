import { createClient } from "@supabase/supabase-js";
import dotenv from "dotenv";

dotenv.config();

const supabase = createClient(
  process.env.VITE_SUPABASE_URL,
  process.env.VITE_SUPABASE_ANON_KEY
);

async function main() {
  // Check if partners_click has data
  const { data: clickData, error: err1 } = await supabase
    .from("partners_click")
    .select("*")
    .limit(10);
  
  console.log("First 10 clicks in partners_click:");
  if (err1) {
    console.error("Error:", err1);
  } else {
    console.log(clickData?.length || 0, "rows");
    if (clickData) {
      clickData.forEach(c => {
        console.log(`  partner_id: ${c.partner_id}, user_id: ${c.user_id}`);
      });
    }
  }

  // Check partner_opportunities
  console.log("\npartner_opportunities sample:");
  const { data: partners, error: err2 } = await supabase
    .from("partner_opportunities")
    .select("id, name")
    .limit(3);
  
  if (err2) {
    console.error("Error:", err2);
  } else {
    partners?.forEach(p => {
      console.log(`  id: ${p.id}, name: ${p.name}`);
    });
  }
}

main().catch(console.error);
