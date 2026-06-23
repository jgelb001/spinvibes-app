-- Course rating & slope on user_rounds, needed for the WHS handicap index.  SAFE TO RE-RUN.
--
-- The handicap index is computed from score differentials: (score − rating) × 113 / slope.
-- That needs each regulation-18 round to carry the tee's course rating and slope. The web
-- app already WRITES these keys (persistRound upserts `rating`/`slope`), but the columns
-- never existed, so those upserts were erroring and silently falling back to localStorage.
-- Adding the columns fixes that AND lets the iOS app persist + read them.
--
-- (round_type and is_practice already exist on the table.)

alter table user_rounds add column if not exists rating numeric;   -- e.g. 70.1
alter table user_rounds add column if not exists slope  integer;   -- e.g. 123
