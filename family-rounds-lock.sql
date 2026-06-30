-- ════════════════════════════════════════════════════════════════════
-- SpinVibes — family_rounds lockdown · PHASE 2 (THE LOCK)
-- ════════════════════════════════════════════════════════════════════
-- ⚠️  DO NOT RUN until BOTH are true:
--       1. family-rounds-rpc.sql (Phase 1) has been applied, and
--       2. the app that routes family-round read/write/delete through those
--          RPCs is DEPLOYED to app.spinvibes.com and tested in production
--          (switch to a kid profile, see their rounds, log + delete one).
--     Until then, leave the open policies in place.
--
-- This removes the open anon policies AND the direct table grants, so the
-- public anon key can no longer enumerate, read, write, or delete ANY
-- family's rounds. All access flows through the Phase-1 SECURITY DEFINER
-- RPCs (which run as the table owner, bypass RLS, and scope every call to
-- the guide-link UUID). The main user's own rounds live in user_rounds and
-- are unaffected.
-- ════════════════════════════════════════════════════════════════════

begin;
  drop policy if exists "anon read family_rounds"   on family_rounds;
  drop policy if exists "anon insert family_rounds" on family_rounds;
  drop policy if exists "anon update family_rounds" on family_rounds;
  drop policy if exists "anon delete family_rounds" on family_rounds;

  alter table family_rounds enable row level security;   -- stays on; no permissive policies = deny-all direct access

  -- Belt-and-suspenders: drop the direct table privileges from the public
  -- roles too, so ONLY the definer RPCs can touch the table.
  revoke select, insert, update, delete on family_rounds from anon;
  revoke select, insert, update, delete on family_rounds from authenticated;
commit;

-- Verify after, with ONLY the public anon key:
--   GET  /rest/v1/family_rounds?select=*                                  → [] / 401 (denied)
--   POST /rest/v1/rpc/get_family_rounds {p_guide_user_id, p_member_key}   → still returns rows
--   App: a kid profile's rounds still load, log, and delete normally.
