-- =============================================================================
-- Coaches can now teach Rifle, Pistol, or Both, with specific distances
-- checked per weapon (Rifle: 10m/50m/300m, Pistol: 10m/25m/50m) instead of
-- a single fixed "Air Rifle 10m" or "Air Pistol 10m" choice.
--
-- Two new columns:
--   teaching_disciplines text[] -- everything they checked, for display
--     (e.g. '{Rifle 10m, Rifle 50m, Pistol 10m}')
--   specializations text[]      -- only the subset that maps to a category
--     this app's fee/qualification/matching system actually understands
--     today (Air Rifle 10m, Air Pistol 10m) — used for real student-coach
--     matching. 50m/300m rifle and 25m/50m pistol are captured and shown
--     on the coach's profile, but this app's fee structure and
--     qualification standards are only built out for the two 10m
--     disciplines right now — extending fees/standards to the longer
--     distances would be a separate, larger piece of work.
--
-- `specialization` (the original single text column) is kept as a
-- human-readable summary string for existing display code, now populated
-- from the full discipline list rather than a single fixed value.
-- =============================================================================

alter table coaches add column if not exists specializations text[] not null default '{}';
alter table coaches add column if not exists teaching_disciplines text[];

-- Backfill existing coaches from their current single specialization value.
update coaches set specializations = array[specialization] where specializations = '{}' and specialization is not null;
update coaches set teaching_disciplines = array[specialization] where teaching_disciplines is null and specialization is not null;

-- Expose specializations (array) alongside the existing columns for the
-- public signup directory, so the student-facing coach picker can match
-- on "does this coach teach my weapon" rather than exact equality.
create or replace view public.coach_directory as
  select id, name, academy_name, specialization, specializations from coaches;
grant select on public.coach_directory to anon, authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text := new.raw_user_meta_data->>'role';
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
    v_specializations := coalesce(
      array(select jsonb_array_elements_text(nullif(new.raw_user_meta_data->>'specializations', '')::jsonb)),
      '{}'
    );
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
    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified, nrai_shooter_id, nrai_email)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      new.raw_user_meta_data->>'phone',
      new.email,
      coalesce(nullif(new.raw_user_meta_data->>'category', ''), 'Air Rifle 10m'),
      coalesce(nullif(new.raw_user_meta_data->>'shooter_category', ''), 'ISSF'),
      new.raw_user_meta_data->>'coach_name',
      v_coach_id,
      v_national_qualified,
      new.raw_user_meta_data->>'nrai_shooter_id',
      new.raw_user_meta_data->>'nrai_email'
    )
    on conflict (id) do nothing;
  elsif v_role = 'coach' then
    insert into public.coaches (id, name, specialization, specializations, teaching_disciplines, academy_name, academy_address, lane_reservation, academy_upi_id, academy_gstin, gst_percent)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(nullif(new.raw_user_meta_data->>'specialization', ''), 'Air Rifle 10m'),
      v_specializations,
      v_teaching_disciplines,
      new.raw_user_meta_data->>'academy_name',
      new.raw_user_meta_data->>'academy_address',
      v_lane_reservation,
      new.raw_user_meta_data->>'academy_upi_id',
      nullif(new.raw_user_meta_data->>'academy_gstin', ''),
      v_gst_percent
    )
    on conflict (id) do nothing;
  end if;

  return new;
exception when others then
  raise warning 'handle_new_user failed: % — %', sqlstate, sqlerrm;
  return new;
end;
$$;
