-- ════════════════════════════════════════════════════════════════════
-- SpinVibes — Kid device pairing  (session 71, Thread C: parent-gate)
-- ════════════════════════════════════════════════════════════════════
-- SAFE TO RUN NOW. Purely additive — new table + new RPCs only, changes NO
-- existing behavior. The kid section's ?u= deep link keeps working exactly
-- as it does today; this adds a second, stronger way to get that same UUID
-- onto a kid device, and a way to re-confirm "a parent is here right now"
-- for destructive actions (forget-device, re-pair).
--
-- WHAT THIS REPLACES: today the family guide-link UUID (?u=...) is a
-- permanent bare secret — whoever has the link (or finds it in browser
-- history / a screenshot / a shared-link) can sync a device to that family
-- forever, with no way to revoke it and no record it happened. That's fine
-- for a beta-of-one but not an honest "parent-provisioned pairing" claim.
--
-- NEW MODEL: a signed-in parent (spinvibes-app, real Supabase auth) mints a
-- short-lived, single-use, 8-character code. The kid device redeems it once
-- to receive the family's UUID (same UUID as today, same ?u= storage on the
-- kid side — no kid-side schema change needed). The code itself is never
-- reusable and expires in 10 minutes. Generating a new code invalidates any
-- code issued before it, so a parent can always kill a leaked code by
-- issuing a fresh one.
--
-- PRIVACY POSTURE (same rule as markers-daily-drills.sql): no kid PII, no
-- device identifiers stored. This table holds only a random code, the
-- family UUID it unlocks, and timestamps.
--
-- ⚠️ KNOWN LIMITATION, flagged not silently accepted: redeem_pairing_code
-- is necessarily anon-callable (the kid device isn't signed in), so it's
-- brute-forceable in principle — 8 alphanumeric chars (~1e12 space) over a
-- 10-minute window makes blind guessing impractical today, but there's no
-- per-caller rate limit at the database layer because anon has no stable
-- identity to throttle by. If this becomes a real target, the fix is an
-- Edge Function in front of this RPC doing IP-based rate limiting — not
-- built here, parked as a Phase 2 item alongside the other RLS phase work
-- in this repo (family-rounds-lock.sql, storage-round-photos-lock.sql).
-- ════════════════════════════════════════════════════════════════════


-- ── Table ───────────────────────────────────────────────────────────
create table if not exists kid_pairing_codes (
  id             uuid primary key default gen_random_uuid(),
  guide_user_id  uuid not null references guide_users(id) on delete cascade,
  code           text not null,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null,
  redeemed_at    timestamptz
);

-- Only one *live* (unredeemed, unexpired) code per family at a time — issuing
-- a new one supersedes the old (see create_pairing_code below, which expires
-- prior codes explicitly; this index is the backstop against a race).
create unique index if not exists kid_pairing_codes_one_live_per_family
  on kid_pairing_codes (guide_user_id)
  where redeemed_at is null;

create index if not exists kid_pairing_codes_lookup on kid_pairing_codes (code);


-- ── RLS: deny all direct access; everything goes through the RPCs below ──
alter table kid_pairing_codes enable row level security;
-- No policies created → authenticated/anon have zero direct table access.
-- (SECURITY DEFINER RPCs below bypass RLS by design, same pattern as the
-- rest of this file's siblings.)


-- ── Mint a code. AUTHENTICATED PARENT ONLY — this is the new, stronger
-- trust boundary: knowing the family UUID is no longer enough to produce a
-- valid pairing code, only being signed in as that family's owner is. ──
create or replace function public.create_pairing_code(p_guide_user_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_owner_auth_id uuid;
  v_code          text;
  v_expires       timestamptz := now() + interval '10 minutes';
  v_chars         text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no 0/O/1/I ambiguity
begin
  select auth_id into v_owner_auth_id from guide_users where id = p_guide_user_id;
  if v_owner_auth_id is null or v_owner_auth_id != auth.uid() then
    raise exception 'not authorized to pair a device for this family';
  end if;

  -- Kill any still-live code for this family before minting the new one —
  -- "generating a new code revokes the old one" is the whole revoke story.
  update kid_pairing_codes set expires_at = now()
   where guide_user_id = p_guide_user_id and redeemed_at is null and expires_at > now();

  -- 8 chars from a 33-char alphabet; collision chance against other *live*
  -- codes is negligible, but loop just in case rather than trust that.
  loop
    v_code := (
      select string_agg(substr(v_chars, (random()*length(v_chars))::int + 1, 1), '')
      from generate_series(1,8)
    );
    exit when not exists (
      select 1 from kid_pairing_codes
       where code = v_code and redeemed_at is null and expires_at > now()
    );
  end loop;

  insert into kid_pairing_codes (guide_user_id, code, expires_at)
  values (p_guide_user_id, v_code, v_expires);

  return jsonb_build_object('code', v_code, 'expires_at', v_expires);
end;
$$;


-- ── Redeem a code. ANON — this is the kid device, not signed in. Returns
-- the family UUID once, on a valid/live/unredeemed code, then burns it. ──
create or replace function public.redeem_pairing_code(p_code text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row kid_pairing_codes;
begin
  select * into v_row from kid_pairing_codes
   where code = upper(trim(p_code)) and redeemed_at is null and expires_at > now()
   limit 1;

  if v_row.id is null then
    raise exception 'invalid or expired code';
  end if;

  update kid_pairing_codes set redeemed_at = now() where id = v_row.id;

  return jsonb_build_object('guide_user_id', v_row.guide_user_id);
end;
$$;


-- ── Explicit revoke — a parent kills any outstanding code without waiting
-- out the 10 minutes (e.g. generated by mistake, or handed to the wrong
-- screen). Same owner check as create_pairing_code. ──
create or replace function public.revoke_pairing_codes(p_guide_user_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_owner_auth_id uuid;
begin
  select auth_id into v_owner_auth_id from guide_users where id = p_guide_user_id;
  if v_owner_auth_id is null or v_owner_auth_id != auth.uid() then
    raise exception 'not authorized to revoke codes for this family';
  end if;

  update kid_pairing_codes set expires_at = now()
   where guide_user_id = p_guide_user_id and redeemed_at is null and expires_at > now();
end;
$$;


-- ── Grants: expose the RPCs (not the table) to the client roles ──
-- create_pairing_code / revoke_pairing_codes still need to be callable by
-- "anon" at the PostgREST layer even though the function body itself
-- enforces auth.uid() — Supabase's authenticated requests still arrive
-- through the anon+JWT combo, this only widens *who can call*, not *who it
-- works for*.
grant execute on function
  public.create_pairing_code(uuid),
  public.redeem_pairing_code(text),
  public.revoke_pairing_codes(uuid)
to anon, authenticated;

-- ✅ Verify after running (replace the uuid with a real guide_users.id; run
-- create_pairing_code as that user's authenticated session, e.g. via the
-- app itself once the UI is wired — the owner check will reject a plain
-- SQL-editor call unless you're impersonating that auth.uid()):
--   select public.redeem_pairing_code('NOTREAL1');  → raises "invalid or expired code"
--   After a real code exists: select public.redeem_pairing_code('<the code>');
--     → {"guide_user_id": "..."}, then redeeming the SAME code again → raises again.
-- Cleanup test rows: delete from kid_pairing_codes where guide_user_id = '<test uuid>';
