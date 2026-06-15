-- Family round EVENTS — iOS native app's family-round log.  SAFE TO RE-RUN.
--
-- Background: the web app's `family_rounds` table stores PER-MEMBER rows
-- (member_key + round jsonb) for family stats sync. The iOS app instead logs
-- one EVENT row per family round (course, players, hole-by-hole, game mode).
-- Two different shapes — so iOS gets its own table here and leaves
-- `family_rounds` (web) untouched.
--
-- iOS supplies: date_played, course_name, course_par, players, holes, totals,
-- is_practice, game_mode, game_mode_data. It does NOT send `id` (defaulted here)
-- and reads back id/date_played/course_name/course_par/players/totals/
-- game_mode/is_practice (extra columns are ignored by the decoder).
--
-- Policies are open (anon read/write), matching the app's current posture.
-- Tighten in the planned security pass.

create table if not exists family_round_events (
  id             text primary key default (gen_random_uuid())::text,
  guide_user_id  uuid,                       -- guide link UUID (?u=...), nullable
  date_played    date,
  course_name    text,
  course_par     int,
  players        jsonb,                       -- array of player keys
  holes          jsonb,                       -- hole-by-hole array
  totals         jsonb,                       -- { playerKey: total }
  is_practice    boolean default false,
  game_mode      text,
  game_mode_data jsonb,
  created_at     timestamptz default now()
);

create index if not exists family_round_events_played on family_round_events (date_played desc);

alter table family_round_events enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies where tablename='family_round_events' and policyname='anon read family_round_events') then
    create policy "anon read family_round_events"   on family_round_events for select using (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='family_round_events' and policyname='anon insert family_round_events') then
    create policy "anon insert family_round_events" on family_round_events for insert with check (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='family_round_events' and policyname='anon update family_round_events') then
    create policy "anon update family_round_events" on family_round_events for update using (true) with check (true);
  end if;
  if not exists (select 1 from pg_policies where tablename='family_round_events' and policyname='anon delete family_round_events') then
    create policy "anon delete family_round_events" on family_round_events for delete using (true);
  end if;
end $$;
