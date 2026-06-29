-- ════════════════════════════════════════════════════════════════════
-- SpinVibes — Markers + Daily-Drill engine  (session 47)  SAFE TO RE-RUN
--
-- Powers the Clubhouse: a `markers` table (every earned collectible) and a
-- `daily_drill_log` (the cumulative daily-drill counter), plus a server-side
-- grant function that awards milestone markers at 7 / 14 / 30 drills.
--
-- PRIVACY POSTURE (built clean from day one — this is the sentence that sells
-- the company, per the retention thesis):
--   • Keyed by member_slug (e.g. "son", "girl", a name-slug) + the family's
--     guide_user_id (the unguessable ?u= link UUID). NO kid PII: no names,
--     ages, free text, or device identifiers stored here.
--   • RLS denies anon SELECT (no table enumeration). ALL access goes through
--     SECURITY DEFINER RPCs — same model as security-rls-hardening.sql.
--   • Writes happen ONLY via record_daily_drill() (atomic count + grant), so
--     milestone logic can never drift between clients and nothing client-
--     supplied decides what's earned.
--
--   ⚠️ COPPA review note (parked, for the paralegal/legal pass): member_slug
--      may derive from a first name. If counsel wants stricter de-identification,
--      switch the client to send an OPAQUE per-member token instead of a name
--      slug — the schema needs no change, only the value the client sends.
--
-- Cumulative + ethical: one drill counts per member per day, the count NEVER
-- resets, a missed day only pauses it. "Best streak" is computed for flair and
-- gates nothing.
-- ════════════════════════════════════════════════════════════════════


-- ── Tables ──────────────────────────────────────────────────────────

-- Every earned collectible disc. category = MarkerCategory rawValue
-- (skill | challenge | practice | course | family | personalBest).
create table if not exists markers (
  id             text primary key default (gen_random_uuid())::text,
  guide_user_id  uuid,                         -- family link (?u=), nullable for local-only
  member_slug    text not null,
  category       text not null,
  marker_id      text not null,                -- e.g. 'milestone_7', a skill-medal id
  source         text,                         -- 'daily_drill_milestone' | 'auto_points' | ...
  earned_at      timestamptz default now()
);

-- Can't earn the same marker twice (per family + member).
create unique index if not exists markers_unique_family
  on markers (guide_user_id, member_slug, marker_id) where guide_user_id is not null;
create unique index if not exists markers_unique_local
  on markers (member_slug, marker_id) where guide_user_id is null;
create index if not exists markers_lookup
  on markers (guide_user_id, member_slug, earned_at desc);

-- One row per completed daily drill. At most one COUNTS per member per day.
create table if not exists daily_drill_log (
  id             text primary key default (gen_random_uuid())::text,
  guide_user_id  uuid,
  member_slug    text not null,
  drill_id       text not null,                -- e.g. 'dd_superhero_finish'
  drill_day      date not null default current_date,
  source         text default 'kid',           -- 'kid' | 'parent' (either taps done)
  created_at     timestamptz default now()
);

-- Enforce "one counted drill per member per day" (cumulative-by-day count).
create unique index if not exists drill_one_per_day_family
  on daily_drill_log (guide_user_id, member_slug, drill_day) where guide_user_id is not null;
create unique index if not exists drill_one_per_day_local
  on daily_drill_log (member_slug, drill_day) where guide_user_id is null;
create index if not exists drill_log_lookup
  on daily_drill_log (guide_user_id, member_slug, drill_day desc);


-- ── RLS: deny anon direct access; reads/writes go through the RPCs below ──
alter table markers          enable row level security;
alter table daily_drill_log  enable row level security;

-- Authenticated family owner may read its own rows directly (covers signed-in
-- parents). Guests/anon never get direct SELECT → no enumeration.
do $$
begin
  if not exists (select 1 from pg_policies where tablename='markers' and policyname='markers_owner_read') then
    create policy "markers_owner_read" on markers for select to authenticated
      using (exists (select 1 from guide_users g
                     where g.id = markers.guide_user_id and g.auth_id = auth.uid()));
  end if;
  if not exists (select 1 from pg_policies where tablename='daily_drill_log' and policyname='drill_owner_read') then
    create policy "drill_owner_read" on daily_drill_log for select to authenticated
      using (exists (select 1 from guide_users g
                     where g.id = daily_drill_log.guide_user_id and g.auth_id = auth.uid()));
  end if;
end $$;


-- ── Core RPC: record a completed drill, return progress + any new marker ──
-- Atomic. Inserts the day's drill (no-op if already counted today), recomputes
-- the cumulative count, grants milestone markers at 7/14/30 not yet held, and
-- returns everything the UI needs to fire the flip-reveal.
create or replace function public.record_daily_drill(
  p_guide_user_id uuid,
  p_member_slug   text,
  p_drill_id      text,
  p_source        text default 'kid'
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_inserted   boolean := false;
  v_count      int;
  v_new        jsonb := '[]'::jsonb;
  v_threshold  int;
  v_marker_id  text;
  v_granted    boolean;
begin
  -- One counted drill per member per day. ON CONFLICT = already did today.
  begin
    insert into daily_drill_log (guide_user_id, member_slug, drill_id, drill_day, source)
    values (p_guide_user_id, p_member_slug, p_drill_id, current_date, coalesce(p_source,'kid'));
    v_inserted := true;
  exception when unique_violation then
    v_inserted := false;
  end;

  -- Cumulative count (never resets) = number of counted drill-days.
  select count(*) into v_count from daily_drill_log d
   where d.member_slug = p_member_slug
     and (d.guide_user_id is not distinct from p_guide_user_id);

  -- Grant milestone markers (slate / practice category) the count has reached.
  foreach v_threshold in array array[7,14,30] loop
    if v_count >= v_threshold then
      v_marker_id := 'milestone_' || v_threshold;
      begin
        insert into markers (guide_user_id, member_slug, category, marker_id, source)
        values (p_guide_user_id, p_member_slug, 'practice', v_marker_id, 'daily_drill_milestone');
        v_granted := true;
      exception when unique_violation then
        v_granted := false;   -- already earned, don't re-fire the reveal
      end;
      if v_granted then
        v_new := v_new || jsonb_build_object('marker_id', v_marker_id,
                                             'category', 'practice',
                                             'threshold', v_threshold);
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'count', v_count,
    'counted_today', v_inserted,
    'new_markers', v_new
  );
end;
$$;


-- ── Read RPCs (security definer; the only way anon/guests see this data) ──

-- All earned markers for a member (newest first).
create or replace function public.get_markers(p_guide_user_id uuid, p_member_slug text)
returns setof markers
language sql stable security definer set search_path = public as $$
  select * from markers
   where member_slug = p_member_slug
     and (guide_user_id is not distinct from p_guide_user_id)
   order by earned_at desc;
$$;

-- Daily-drill progress: cumulative count, last day, and FLAIR-ONLY streaks
-- (current + best). Streaks gate nothing — they're a bragging stat only.
create or replace function public.get_drill_progress(p_guide_user_id uuid, p_member_slug text)
returns jsonb
language sql stable security definer set search_path = public as $$
  with d as (
    select distinct drill_day from daily_drill_log
     where member_slug = p_member_slug
       and (guide_user_id is not distinct from p_guide_user_id)
  ),
  g as (  -- gaps-and-islands: consecutive days share a group key
    select drill_day,
           drill_day - (row_number() over (order by drill_day))::int as grp
      from d
  ),
  runs as (
    select grp, count(*)::int as len, max(drill_day) as ends_on
      from g group by grp
  )
  select jsonb_build_object(
    'count',          (select count(*) from d),
    'last_day',       (select max(drill_day) from d),
    'best_streak',    coalesce((select max(len) from runs), 0),
    'current_streak', coalesce((
        select len from runs
         where ends_on >= current_date - 1   -- today or yesterday = still "going"
         order by ends_on desc limit 1), 0)
  );
$$;


-- ── Retention instrumentation (track B) — AGGREGATE ONLY, zero PII ──
-- "Are N families back weekly." Counts distinct active families/members per
-- ISO week. No member identities returned. Intended for an admin/owner view;
-- granted to authenticated, but consider locking to a service role in prod.
create or replace function public.drill_weekly_active()
returns table(week date, active_families int, active_members int)
language sql stable security definer set search_path = public as $$
  select date_trunc('week', drill_day)::date as week,
         count(distinct guide_user_id)::int  as active_families,
         count(distinct member_slug)::int    as active_members
    from daily_drill_log
   group by 1 order by 1 desc;
$$;


-- ── Grants: expose the RPCs (not the tables) to the client roles ──
grant execute on function
  public.record_daily_drill(uuid, text, text, text),
  public.get_markers(uuid, text),
  public.get_drill_progress(uuid, text),
  public.drill_weekly_active()
to anon, authenticated;

-- ✅ Verify after running:
--   select public.record_daily_drill(null, 'test_kid', 'dd_superhero_finish', 'kid');
--     → {"count":1,"counted_today":true,"new_markers":[]}
--   (call 7 times across 7 days, or seed rows) → new_markers includes milestone_7.
--   select public.get_drill_progress(null, 'test_kid');  → count + streak flair.
--   With ONLY the anon key: GET /rest/v1/markers?select=*  → denied (RLS).
--   POST /rest/v1/rpc/get_markers {p_guide_user_id:null,p_member_slug:'test_kid'} → rows.
-- Cleanup test rows: delete from daily_drill_log where member_slug='test_kid';
--                    delete from markers where member_slug='test_kid';
