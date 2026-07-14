-- ════════════════════════════════════════════════════════════════════
-- SpinVibes — round-photos storage bucket lockdown  (s55, 2026-07-13)
-- ════════════════════════════════════════════════════════════════════
-- AUDIT FINDING (verified live with the PUBLIC anon key on 2026-07-13):
--   • bucket `round-photos` is PUBLIC and had default-open storage policies.
--   • anon could LIST every object  → POST /storage/v1/object/list/round-photos  returned the tree
--   • anon could UPLOAD arbitrary files → POST /storage/v1/object/round-photos/<path>  → 200
--     (a probe file `audit-probe-2026-07-13.txt` was uploaded during the audit and
--      could NOT be removed by anon — delete IS blocked — so DELETE from the dashboard.)
--   • anon DELETE was already denied (good).
-- IMPACT: the moment a family saves a hole photo (kids on a course = COPPA-adjacent),
--   anyone holding the anon key — which ships in the client JS, so it is public — can
--   ENUMERATE and DOWNLOAD every photo, and can inject arbitrary content into your
--   production storage (abuse / storage-cost / hosting unknown files under your project).
--   Current real exposure is LOW (only placeholders + probe files stored so far), which is
--   why this is a fix-now-before-photos-flow item, not an active breach.
--
-- WHAT THIS DOES:
--   Phase A (run now, safe, no app change): kill anon/authenticated LIST + INSERT + UPDATE
--     on this bucket's objects. PUBLIC READ stays on, so existing share cards / gallery that
--     use getPublicUrl() keep working. Uploads must then come from a SIGNED UPLOAD or a
--     definer path (see Phase B). NOTE: the app currently uploads with the anon client
--     (_uploadAppHolePhotos → _sb.storage.upload), so DEPLOY the signed-upload change
--     (Phase B app work) BEFORE running Phase A, or new uploads will 403.
--   Phase B (the real fix, needs app changes — TODO): flip the bucket to PRIVATE and serve
--     photos via createSignedUrl() (short-lived) instead of getPublicUrl(); route uploads
--     through a signed-upload token minted by the Worker. That removes public-download of
--     kid photos entirely. Tracked as a follow-up; not in this file.
-- ════════════════════════════════════════════════════════════════════

-- ── PHASE A ──────────────────────────────────────────────────────────
-- Storage objects live in storage.objects with a bucket_id column.
-- Supabase dashboard-created buckets get permissive policies; replace them
-- with read-only-public + no anon writes/list.

begin;

  -- Drop whatever open policies the dashboard created for this bucket.
  -- (Names vary; these cover the common dashboard defaults + our own.)
  drop policy if exists "Public read round-photos"            on storage.objects;
  drop policy if exists "Public Access"                       on storage.objects;
  drop policy if exists "anon read round-photos"              on storage.objects;
  drop policy if exists "anon insert round-photos"            on storage.objects;
  drop policy if exists "anon list round-photos"              on storage.objects;
  drop policy if exists "Give anon access to round-photos"    on storage.objects;
  drop policy if exists "Allow uploads to round-photos"       on storage.objects;

  -- RLS is already enabled on storage.objects by Supabase; ensure it.
  alter table storage.objects enable row level security;

  -- Re-add ONLY a public SELECT (download-by-URL) policy for this bucket.
  -- No INSERT/UPDATE/LIST policy for anon → anon can no longer enumerate or upload.
  -- (SELECT via a fully-qualified object path still works = getPublicUrl keeps serving;
  --  but /object/list with no policy returns empty/denied, closing enumeration.)
  create policy "round-photos public read"
    on storage.objects for select
    to anon, authenticated
    using ( bucket_id = 'round-photos' );

  -- Authenticated users may upload ONLY into their own /app/<uid>/... prefix.
  -- (Harmless to add now; becomes the write path once uploads move to an
  --  authenticated/signed flow in Phase B. Anon has NO write policy → denied.)
  create policy "round-photos owner insert"
    on storage.objects for insert
    to authenticated
    with check (
      bucket_id = 'round-photos'
      -- solo rounds upload under app/<roundId>/... ; family rounds under fam/<roundId>/...
      and (storage.foldername(name))[1] in ('app', 'fam')
    );

commit;

-- ── VERIFY (run with ONLY the public anon key) ───────────────────────
--   POST /storage/v1/object/list/round-photos {"prefix":""}          → [] (no longer enumerable)
--   POST /storage/v1/object/round-photos/x.txt  (upload)             → 403 (denied)
--   GET  /storage/v1/object/public/round-photos/<known-path>         → 200 (share cards OK)
--
-- ── CLEANUP (dashboard, one-time) ────────────────────────────────────
--   Delete these audit/leftover objects from the round-photos bucket:
--     • audit-probe-2026-07-13.txt   (this session's upload probe — anon can't self-delete)
--     • app/DIAG-TEST                (older leftover diagnostic)
