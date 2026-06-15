-- Per-member round history for user_rounds.  SAFE TO RE-RUN.
--
-- The iOS app (and, going forward, the web app) tags each solo round with the
-- active profile it was logged under: "main" for the account holder, or a member
-- name slug for a family member. My Game then filters round history + stats +
-- handicap to the active profile — mirroring the web app's per-member `RK()` keys.
--
-- Existing rows predate this column, so they're backfilled to "main" (the holder).

alter table user_rounds add column if not exists member_key text default 'main';

update user_rounds set member_key = 'main' where member_key is null;

create index if not exists user_rounds_member on user_rounds (user_id, member_key, date_played desc);
