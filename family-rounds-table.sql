-- Family stats sync — one-time setup.  SAFE TO RE-RUN.
-- Drops any partial/old version first, then creates a clean table. There's no
-- real data in this table yet, so the drop is harmless.
--
-- After it runs, each family member's rounds save to the cloud keyed by the
-- guide link (?u=UUID) + member key, so they follow the family across devices.
-- The app no-ops gracefully until this exists.
--
-- Note: policies are open (anon read/write), matching the current app's posture
-- (guide_users / guide_rounds are already accessed with the anon key). Tighten
-- these in the planned security pass.

drop table if exists family_rounds cascade;

create table family_rounds (
  id            text primary key,        -- matches the round's id ("<ts>-<memberKey>")
  guide_user_id uuid,                    -- the guide link UUID (?u=...). No FK, kept simple.
  member_key    text not null,           -- slug of the member's name (e.g. "charlie")
  round         jsonb not null,          -- the full round record the app stores
  date_played   date,
  created_at    timestamptz default now()
);

create index family_rounds_lookup on family_rounds (guide_user_id, member_key);

alter table family_rounds enable row level security;

create policy "anon read family_rounds"   on family_rounds for select using (true);
create policy "anon insert family_rounds" on family_rounds for insert with check (true);
create policy "anon update family_rounds" on family_rounds for update using (true) with check (true);
create policy "anon delete family_rounds" on family_rounds for delete using (true);
