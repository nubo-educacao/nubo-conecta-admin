-- Check which partner_ids in partners_click don't exist in partner_opportunities
SELECT 
  pc.partner_id,
  COUNT(*) as click_count,
  p.name as partner_name
FROM public.partners_click pc
LEFT JOIN public.partner_opportunities po ON pc.partner_id = po.id
LEFT JOIN public.partners p ON pc.partner_id = p.id
WHERE po.id IS NULL
GROUP BY pc.partner_id, p.name
ORDER BY click_count DESC;
