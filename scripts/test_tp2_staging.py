"""TP-2 staging regressions. Requires psycopg2 and STAGING_DATABASE_URL.
Fixtures run in transactions and always roll back. Production is refused.
Run: python scripts/test_tp2_staging.py
"""
import os
import unittest
from urllib.parse import urlsplit
from uuid import uuid4
import psycopg2
import psycopg2.extras

class TrackingContracts(unittest.TestCase):
    def setUp(self):
        url = os.environ["STAGING_DATABASE_URL"]
        if urlsplit(url).hostname != "db.yfgciamhzjvarwgzosto.supabase.co":
            raise RuntimeError("Only the approved staging project is allowed")
        self.db = psycopg2.connect(url, connect_timeout=10)
        self.addCleanup(self.db.close)
        self.addCleanup(self.db.rollback)
        self.q = self.db.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
        self.admin, self.partner, self.other, self.student = [str(uuid4()) for _ in range(4)]
        self.inst, self.inst2, self.opp, self.opp2, self.mec, self.mec2 = [str(uuid4()) for _ in range(6)]
        for uid in [self.admin, self.partner, self.other, self.student]:
            self.q.execute("INSERT INTO auth.users(id) VALUES (%s)", (uid,))
            self.q.execute("INSERT INTO public.user_profiles(id,full_name) VALUES (%s,'TP2 fixture') ON CONFLICT(id) DO NOTHING", (uid,))
        self.q.execute("INSERT INTO public.user_permissions(user_id,permission) VALUES (%s,'Parceiros'),(%s,'Dashboard')", (self.admin,self.admin))
        for iid in [self.inst,self.inst2]:
            self.q.execute("INSERT INTO public.institutions(id,name,is_partner) VALUES (%s,'TP2 fixture',true)",(iid,))
            self.q.execute("INSERT INTO public.partner_institutions(institution_id) VALUES (%s)",(iid,))
        self.q.execute("INSERT INTO public.partners_users(user_id,partner_id) VALUES (%s,%s)", (self.partner,self.inst))
        self.q.execute("INSERT INTO public.partner_opportunities(id,institution_id,name,opportunity_type) VALUES (%s,%s,'TP2 fixture','programa de bolsa')", (self.opp,self.inst))
        self.q.execute("INSERT INTO public.partner_opportunities(id,institution_id,name,opportunity_type) VALUES (%s,%s,'TP2 other institution','programa de bolsa')", (self.opp2,self.inst2))
        self.claim(self.admin)

    def claim(self, uid, role="authenticated"):
        self.q.execute("RESET ROLE")
        self.q.execute("SELECT set_config('request.jwt.claim.sub',%s,true),set_config('request.jwt.claim.role',%s,true),set_config('request.jwt.claims',%s,true)",
                       (uid,role,psycopg2.extras.Json({"sub":uid,"role":role})))
        self.q.execute("SET LOCAL ROLE " + role)

    def event(self, kind, entity, seconds, source="card", count=1, user=None, anonymous=None, domain="mec_opportunity", days=0):
        self.q.execute("RESET ROLE")
        self.q.execute("""INSERT INTO public.engagement_events(event_id,event_type,entity_type,entity_id,user_id,anonymous_id,source,event_count,destination_url,occurred_at)
            VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,now()-interval '1 hour'+%s*interval '1 second'-%s*interval '1 day')""",
            ("tp2-test:"+str(uuid4()),kind,domain,entity,user or (None if anonymous else self.student),anonymous,source,count,"https://example.com" if kind=="redirect" else None,seconds,days))
        self.claim(self.admin)

    def test_weighted_b2b_distinct_people_period_and_portal(self):
        self.event("card_click",self.opp,0,count=7,domain="partner_opportunity",source="legacy_partners_click_aggregate",days=40)
        self.event("card_click",self.opp,1,count=1,domain="partner_opportunity")
        self.event("card_click",self.opp2,1,count=3,domain="partner_opportunity")
        self.q.execute("RESET ROLE")
        self.q.execute("INSERT INTO public.student_applications(user_id,partner_id,status) VALUES (%s,%s,'DRAFT'),(%s,%s,'SUBMITTED')", (self.student,self.opp,self.student,self.opp))
        self.claim(self.admin)
        self.q.execute("SELECT * FROM public.get_tp2_partner_funnel(%s,NULL)",(self.inst,))
        row=self.q.fetchone()
        self.assertEqual((row["total_card_clicks"],row["total_unique_clicks"],row["total_applications_started"],row["total_applications_completed"]),(8,1,1,1))
        self.q.execute("SELECT total_card_clicks FROM public.get_tp2_partner_funnel(%s,7)",(self.inst,))
        self.assertEqual(self.q.fetchone()["total_card_clicks"],1)
        self.claim(self.partner)
        self.q.execute("SELECT partner_id FROM public.vw_partner_funnel")
        self.assertEqual([str(r["partner_id"]) for r in self.q.fetchall()],[self.inst])
        self.q.execute("SELECT * FROM public.get_tp2_partner_funnel(%s,NULL)",(self.inst2,))
        self.assertEqual(self.q.fetchall(),[])

    def test_mec_causal_order_entity_period_legacy_and_anonymous(self):
        self.event("card_view",self.mec,0)
        self.event("card_click",self.mec,1)
        self.event("redirect",self.mec,2)
        self.event("card_view",self.mec,3,anonymous="tp2-anon")
        self.event("card_click",self.mec2,0)
        self.event("card_view",self.mec2,1)
        self.event("redirect",self.mec2,2)
        self.event("card_click",self.mec,4,source="legacy_test",count=7)
        self.q.execute("SELECT public.get_mec_engagement_dashboard(%s,7) AS data",(self.mec,))
        data=self.q.fetchone()["data"]
        self.assertEqual((data["totals"]["card_view"],data["totals"]["card_click"],data["totals"]["redirect"]),(2,8,1))
        self.assertEqual((data["cohort"]["viewers"],data["cohort"]["clickers"],data["cohort"]["redirectors"]),(2,1,1))
        self.assertEqual(data["totals"]["distinct_users"],1)
        self.q.execute("SELECT public.get_mec_engagement_dashboard(%s,7) AS data",(self.mec2,))
        self.assertEqual(self.q.fetchone()["data"]["cohort"]["redirectors"],0)

    def test_redirect_opportunity_contract_and_institution_portal(self):
        self.event("redirect",self.opp,0,domain="partner_opportunity")
        self.event("redirect",self.opp2,0,domain="partner_opportunity")
        self.q.execute("SELECT partner_id FROM public.get_partner_redirect_users(%s)",(self.opp,))
        self.assertEqual(str(self.q.fetchone()["partner_id"]),self.opp)
        self.claim(self.partner)
        self.q.execute("SELECT partner_id FROM public.get_partner_institution_redirect_users(%s)",(self.inst,))
        self.assertEqual(str(self.q.fetchone()["partner_id"]),self.opp)
        self.q.execute("SELECT * FROM public.get_partner_institution_redirect_users(%s)",(self.inst2,))
        self.assertEqual(self.q.fetchall(),[])
        self.q.execute("SELECT * FROM public.get_partner_redirect_users(%s)",(self.opp2,))
        self.assertEqual(self.q.fetchall(),[])

    def test_unprivileged_cannot_read_admin_metrics_or_redirect_pii(self):
        self.claim(self.other)
        for sql in ["SELECT public.get_mec_engagement_dashboard(NULL,7)", "SELECT * FROM public.get_partner_redirect_users(NULL)", "SELECT * FROM public.get_tp2_partner_funnel(NULL,NULL)"]:
            self.q.execute("SAVEPOINT access_test")
            with self.assertRaises(psycopg2.errors.InsufficientPrivilege):
                self.q.execute(sql)
            self.q.execute("ROLLBACK TO SAVEPOINT access_test")
        self.claim(self.other,"anon")
        self.q.execute("SAVEPOINT access_test")
        with self.assertRaises(psycopg2.errors.InsufficientPrivilege):
            self.q.execute("SELECT public.get_mec_engagement_dashboard(NULL,7)")
        self.q.execute("ROLLBACK TO SAVEPOINT access_test")

    def test_missing_role_claim_is_not_admin_authorization(self):
        self.claim(self.other)
        self.q.execute("SELECT set_config('request.jwt.claim.role','',true),set_config('request.jwt.claims','{}',true)")
        self.q.execute("SAVEPOINT access_test")
        with self.assertRaises(psycopg2.errors.InsufficientPrivilege):
            self.q.execute("SELECT public.get_mec_engagement_dashboard(NULL,7)")
        self.q.execute("ROLLBACK TO SAVEPOINT access_test")

    def test_cohort_does_not_borrow_steps_across_entities_or_periods(self):
        self.event("card_view",self.mec,0,days=40)
        self.event("card_click",self.mec,1)
        self.event("redirect",self.mec,2)
        self.event("card_view",self.mec2,0)
        self.q.execute("SELECT public.get_mec_engagement_dashboard(NULL,7) AS data")
        data=self.q.fetchone()["data"]
        self.assertEqual(data["cohort"],{"viewers":1,"clickers":0,"redirectors":0})
        self.assertEqual(data["totals"]["redirect"],1)

if __name__ == "__main__":
    unittest.main()

