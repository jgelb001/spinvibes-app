-- ════════════════════════════════════════════════════════════════════
-- SpinVibes — family_rounds lockdown · PHASE 1 (additive RPCs)
-- ════════════════════════════════════════════════════════════════════
-- SAFE TO RUN NOW. Purely additive — changes NO existing behavior. Direct
-- anon table access keeps working until PHASE 2 (family-rounds-lock.sql),
-- which is only run after the app that uses these RPCs is deployed + tested.
--
-- Mirrors security-rls-hardening.sql. Capability model: the guide-link UUID
-- (?u=...) is the secret. Whoever holds it can manage that ONE family's
-- member rounds — exactly the posture get_guide_user already uses. Phase 2
-- revokes the blanket anon table access that today lets the public anon key
-- read/alter EVERY family's rounds; reads/writes/deletes then flow through
-- these definer RPCs, each scoped to the guide-link UUID.
-- ════════════════════════════════════════════════════════════════════

-- READ — one family's rounds for one member, by the guide-link UUID.
create or replace function public.get_family_rounds(p_guide_user_id uuid, p_member_key text)
returns setof family_rounds
language sql stable security definer set search_path = public as $$
  select * from family_rounds
  where guide_user_id = p_guide_user_id and member_key = p_member_key
  order by date_played asc;
$$;

-- WRITE (upsert) — save/update one member round. Guarded two ways:
--   • only for a guide_user_id that actually exists (no junk to random UUIDs)
--   • on id-conflict, only the OWNING family may overwrite the row (an id guess
--     from another family can't hijack it).
create or replace function public.upsert_family_round(
  p_id text, p_guide_user_id uuid, p_member_key text, p_round jsonb, p_date date)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from guide_users where id = p_guide_user_id) then
    raise exception 'unknown guide_user_id';
  end if;
  insert into family_rounds (id, guide_user_id, member_key, round, date_played)
  values (p_id, p_guide_user_id, p_member_key, p_round, coalesce(p_date, current_date))
  on conflict (id) do update
    set round       = excluded.round,
        member_key  = excluded.member_key,
        date_played = excluded.date_played
    where family_rounds.guide_user_id = p_guide_user_id;
end;
$$;

-- DELETE — remove one member round, scoped to the owning family + member.
create or replace function public.delete_family_round(
  p_id text, p_guide_user_id uuid, p_member_key text)
returns void
language sql security definer set search_path = public as $$
  delete from family_rounds
  where id = p_id and guide_user_id = p_guide_user_id and member_key = p_member_key;
$$;

grant execute on function
  public.get_family_rounds(uuid, text),
  public.upsert_family_round(text, uuid, text, jsonb, date),
  public.delete_family_round(text, uuid, text)
to anon, authenticated;

-- ✅ END PHASE 1. Nothing above weakens current access. Verify:
--   select * from public.get_family_rounds('a1aaaaaa-0000-4000-8000-000000000001','son');  → rows
--   select public.upsert_family_round('audit-x','a1aaaaaa-0000-4000-8000-000000000001','son','{"t":1}'::jsonb, current_date);  → ok
--   select public.delete_family_round('audit-x','a1aaaaaa-0000-4000-8000-000000000001','son');  → ok
