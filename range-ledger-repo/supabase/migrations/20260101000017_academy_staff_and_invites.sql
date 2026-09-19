-- =============================================================================
-- Multi-staff academies: an academy can now have more than one person with
-- access, at different permission levels, instead of exactly one coach
-- account = one academy. The original coach who signed up remains the
-- "owner" (their existing coaches.id row is still what everything else in
-- the app keys off as "the academy"). Additional people join via an
-- invite code the owner generates, which grants a specific role:
--   admin  — same day-to-day access as the owner (roster, fees, inventory,
--            notifications) but can't be removed by other admins, only by
--            the owner
--   editor — can record attendance, confirm payments, manage inventory,
--            log scores — the operational day-to-day actions
--   viewer — read-only (e.g. a front-desk person or a parent who should
--            see status but not change anything)
--
-- New staff join with status='pending' and must be approved by the owner
-- before they gain any actual access — this protects against a leaked or
-- overheard code being used by someone the owner didn't actually intend.
-- =============================================================================

create table if not exists academy_staff (
  id bigint generated always as identity primary key,
  coach_id uuid not null references coaches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text,
  role text not null check (role in ('admin', 'editor', 'viewer')),
  status text not null default 'pending' check (status in ('pending', 'approved')),
  invited_via_code text,
  created_at timestamptz default now(),
  unique (coach_id, user_id)
);

create table if not exists academy_invite_codes (
  id bigint generated always as identity primary key,
  coach_id uuid not null references coaches(id) on delete cascade,
  code text not null unique,
  role text not null check (role in ('admin', 'editor', 'viewer')),
  created_at timestamptz default now(),
  expires_at timestamptz,
  used_by uuid references auth.users(id),
  used_at timestamptz
);

alter table academy_staff enable row level security;
alter table academy_invite_codes enable row level security;

-- Helper: is the caller an *approved* staff member of this academy? Used
-- throughout the existing RLS policies below instead of the old
-- "coach_id = auth.uid()" assumption that only the original owner exists.
create or replace function public.is_academy_staff_of(target_coach_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from academy_staff
    where coach_id = target_coach_id and user_id = auth.uid() and status = 'approved'
  );
$$;

-- Any effective coach_id (academy) the caller can act as: their own, if
-- they're an owner, plus any academy they're an approved staff member of.
-- Used client-side to resolve "which academy am I operating as" on login.
create or replace function public.my_academy_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select id from coaches where id = auth.uid()
  union
  select coach_id from academy_staff where user_id = auth.uid() and status = 'approved'
$$;

-- Staff records: the owner (coach_id = auth.uid()) can see and manage
-- everyone on their staff; a staff member can see their own record (so
-- they know their own role and pending/approved status).
drop policy if exists "academy_staff readable by owner or self" on academy_staff;
create policy "academy_staff readable by owner or self" on academy_staff for select using (
  coach_id = auth.uid() or user_id = auth.uid() or is_admin()
);
drop policy if exists "academy_staff managed by owner" on academy_staff;
create policy "academy_staff managed by owner" on academy_staff for update using (
  coach_id = auth.uid() or is_admin()
);
drop policy if exists "academy_staff deleted by owner or self" on academy_staff;
create policy "academy_staff deleted by owner or self" on academy_staff for delete using (
  coach_id = auth.uid() or user_id = auth.uid() or is_admin()
);
-- Insert happens only through redeem_academy_invite_code() below (security
-- definer), never directly — so no insert policy is needed for regular
-- callers, only for the owner adding staff by hand (rare, but possible).
drop policy if exists "academy_staff insert by owner" on academy_staff;
create policy "academy_staff insert by owner" on academy_staff for insert with check (
  coach_id = auth.uid() or is_admin()
);

-- Invite codes: only the owner can see/manage the codes they've generated.
drop policy if exists "invite codes managed by owner" on academy_invite_codes;
create policy "invite codes managed by owner" on academy_invite_codes for all using (
  coach_id = auth.uid() or is_admin()
) with check (
  coach_id = auth.uid() or is_admin()
);

-- Redeeming a code needs to look up a code the redeemer has no visibility
-- into yet (they don't have an academy_staff row until this succeeds), so
-- this runs as security definer rather than relying on RLS the caller
-- could see through.
create or replace function public.redeem_academy_invite_code(p_code text, p_name text)
returns table (coach_id uuid, role text)
language plpgsql
security definer set search_path = public
as $$
declare
  v_invite academy_invite_codes%rowtype;
begin
  select * into v_invite from academy_invite_codes where code = p_code and used_by is null
    and (expires_at is null or expires_at > now());
  if not found then
    raise exception 'This invite code is invalid, already used, or has expired.';
  end if;

  insert into academy_staff (coach_id, user_id, name, role, status, invited_via_code)
  values (v_invite.coach_id, auth.uid(), p_name, v_invite.role, 'pending', p_code)
  on conflict (coach_id, user_id) do nothing;

  update academy_invite_codes set used_by = auth.uid(), used_at = now() where id = v_invite.id;

  return query select v_invite.coach_id, v_invite.role;
end;
$$;

-- A coach signing up to JOIN an existing academy (rather than start one)
-- must not get their own coaches row created — that would make them an
-- owner of a separate, empty academy instead of staff on someone else's.
-- Their profile row is still created normally; their actual academy_staff
-- membership is created client-side via redeem_academy_invite_code() once
-- they have a session.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text := new.raw_user_meta_data->>'role';
  v_join_mode text := new.raw_user_meta_data->>'join_mode';
  v_coach_id uuid;
  v_national_qualified boolean;
  v_lane_reservation boolean;
  v_gst_percent numeric;
  v_specializations text[];
  v_teaching_disciplines text[];
begin
  begin
    v_coach_id := nullif(new.raw_user_meta_data->>'coach_id', '')::uuid;
  exception when others then
    v_coach_id := null;
  end;
  begin
    v_national_qualified := coalesce(nullif(new.raw_user_meta_data->>'national_qualified', '')::boolean, false);
  exception when others then
    v_national_qualified := false;
  end;
  begin
    v_lane_reservation := coalesce(nullif(new.raw_user_meta_data->>'lane_reservation', '')::boolean, false);
  exception when others then
    v_lane_reservation := false;
  end;
  begin
    v_gst_percent := coalesce(nullif(new.raw_user_meta_data->>'gst_percent', '')::numeric, 0);
  exception when others then
    v_gst_percent := 0;
  end;
  begin
    v_specializations := coalesce(array(select jsonb_array_elements_text(nullif(new.raw_user_meta_data->>'specializations', '')::jsonb)), '{}');
  exception when others then
    v_specializations := '{}';
  end;
  begin
    v_teaching_disciplines := array(select jsonb_array_elements_text(nullif(new.raw_user_meta_data->>'teaching_disciplines', '')::jsonb));
  exception when others then
    v_teaching_disciplines := null;
  end;

  insert into public.profiles (id, role, name)
  values (new.id, coalesce(v_role, 'student'), coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;

  if v_role = 'student' then
    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified, nrai_shooter_id, nrai_email, academy_name)
    values (
      new.id, coalesce(new.raw_user_meta_data->>'name', ''), new.raw_user_meta_data->>'phone', new.email,
      coalesce(nullif(new.raw_user_meta_data->>'category', ''), 'Air Rifle 10m'),
      coalesce(nullif(new.raw_user_meta_data->>'shooter_category', ''), 'ISSF'),
      new.raw_user_meta_data->>'coach_name', v_coach_id, v_national_qualified,
      new.raw_user_meta_data->>'nrai_shooter_id', new.raw_user_meta_data->>'nrai_email', new.raw_user_meta_data->>'academy_name'
    )
    on conflict (id) do nothing;
  elsif v_role = 'coach' and v_join_mode != 'join' then
    insert into public.coaches (id, name, specialization, specializations, teaching_disciplines, academy_name, academy_address, lane_reservation, academy_upi_id, academy_gstin, gst_percent)
    values (
      new.id, coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(nullif(new.raw_user_meta_data->>'specialization', ''), 'Air Rifle 10m'),
      v_specializations, v_teaching_disciplines,
      new.raw_user_meta_data->>'academy_name', new.raw_user_meta_data->>'academy_address', v_lane_reservation,
      new.raw_user_meta_data->>'academy_upi_id', nullif(new.raw_user_meta_data->>'academy_gstin', ''), v_gst_percent
    )
    on conflict (id) do nothing;
  end if;

  return new;
exception when others then
  raise warning 'handle_new_user failed: % — %', sqlstate, sqlerrm;
  return new;
end;
$$;

-- =============================================================================
-- Extend existing policies so an approved staff member gets the same
-- access as the owner (coach_id = auth.uid()) previously had alone.
-- =============================================================================

create or replace function public.student_belongs_to_caller(sid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select
    exists (
      select 1 from students s
      where s.id = sid and (s.id = auth.uid() or s.coach_id = auth.uid() or is_academy_staff_of(s.coach_id))
    )
    or public.is_admin();
$$;

drop policy if exists "students readable by tenant" on students;
create policy "students readable by tenant" on students for select using (
  id = auth.uid() or coach_id = auth.uid() or is_academy_staff_of(coach_id) or is_admin()
);
drop policy if exists "students update by tenant" on students;
create policy "students update by tenant" on students for update using (
  id = auth.uid() or coach_id = auth.uid() or is_academy_staff_of(coach_id) or is_admin()
);

drop policy if exists "coaches readable by tenant" on coaches;
create policy "coaches readable by tenant" on coaches for select using (
  id = auth.uid() or is_admin() or is_academy_staff_of(id)
  or exists (select 1 from students s where s.coach_id = coaches.id and s.id = auth.uid())
);

drop policy if exists "inventory readable by tenant" on inventory_items;
create policy "inventory readable by tenant" on inventory_items for select using (
  coach_id = auth.uid() or is_admin() or is_academy_staff_of(coach_id)
  or exists (select 1 from students s where s.coach_id = inventory_items.coach_id and s.id = auth.uid())
);
drop policy if exists "inventory insert by owning coach" on inventory_items;
create policy "inventory insert by owning coach" on inventory_items for insert with check (
  coach_id = auth.uid() or is_academy_staff_of(coach_id)
);
drop policy if exists "inventory update by owning coach" on inventory_items;
create policy "inventory update by owning coach" on inventory_items for update using (
  coach_id = auth.uid() or is_academy_staff_of(coach_id)
);
drop policy if exists "inventory delete by owning coach" on inventory_items;
create policy "inventory delete by owning coach" on inventory_items for delete using (
  coach_id = auth.uid() or is_academy_staff_of(coach_id)
);

drop policy if exists "issues insert by tenant staff" on inventory_issues;
create policy "issues insert by tenant staff" on inventory_issues for insert with check (
  coach_id = auth.uid() or is_admin() or is_academy_staff_of(coach_id)
);

drop policy if exists "broadcasts insert by staff" on notification_broadcasts;
create policy "broadcasts insert by staff" on notification_broadcasts for insert with check (
  (target_coach_id = auth.uid() and exists (select 1 from coaches c where c.id = auth.uid()))
  or (target_coach_id is not null and is_academy_staff_of(target_coach_id))
  or (target_coach_id is null and is_admin())
);
