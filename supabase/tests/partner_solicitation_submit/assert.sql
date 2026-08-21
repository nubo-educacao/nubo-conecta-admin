\pset border 2
\echo '=== O BUG QUE MOTIVOU A RPC: dedupe por SELECT anônimo é cego ==='
SET ROLE anon;
INSERT INTO public.partner_solicitations (institution_name, contact_name, email, how_did_you_know)
  VALUES ('Instituto Sol','Maria','maria@sol.org','Indicação');
SELECT count(*) AS anon_enxerga FROM public.partner_solicitations;
RESET ROLE;
SELECT count(*) AS existe_de_fato FROM public.partner_solicitations;
\echo '   ^ anon_enxerga=0 e existe_de_fato=1: era isto que a dedupe consultava.'

\echo ''
\echo '=== A RPC deduplica porque é SECURITY DEFINER ==='
SET ROLE anon;
SELECT 'reenvio do que ja existe' AS caso,
       public.submit_partner_solicitation('Instituto Sol','Maria','Indicação',NULL,'maria@sol.org',NULL,'200.1.1.1')->>'status' AS status;
SELECT 'whatsapp formatado diferente = mesmo contato' AS caso,
       public.submit_partner_solicitation('Colegio Ponte','Ana','Busca','(11) 98888-7777',NULL,NULL,'200.1.1.2')->>'status' AS primeiro,
       public.submit_partner_solicitation('Colegio Ponte','Ana','Busca','11988887777',NULL,NULL,'200.1.1.2')->>'status' AS segundo;

\echo ''
\echo '=== Validação ==='
SELECT public.submit_partner_solicitation('X','Y','Z',NULL,NULL,NULL,'200.1.1.3')->>'field' AS sem_contato,
       public.submit_partner_solicitation('  ','Y','Z',NULL,'a@b.co',NULL,'200.1.1.3')->>'field' AS sem_instituicao;

\echo ''
\echo '=== Rate limit: 6 tentativas do mesmo IP, limite 5/hora ==='
SELECT i, public.submit_partner_solicitation('Escola '||i,'Contato '||i,'Busca',NULL,'c'||i||'@x.org',NULL,'201.9.9.9')->>'status' AS status
FROM generate_series(1,6) i;
SELECT 'outro IP passa' AS caso,
       public.submit_partner_solicitation('Escola Nova','C','Busca',NULL,'nova@x.org',NULL,'201.9.9.10')->>'status' AS status;
RESET ROLE;
