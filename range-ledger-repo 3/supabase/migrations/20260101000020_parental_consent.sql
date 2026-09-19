-- =============================================================================
-- Parental consent capture for minor shooters. This records that consent
-- was claimed at signup — a name, a contact, and a timestamp — which is
-- meaningfully better than nothing, but it is NOT the same as verifying
-- that the parent themselves actually gave it. A robust implementation
-- would separately confirm with the parent through a channel the minor
-- doesn't control (e.g. emailing the parent a confirmation link and
-- only activating the account once they click it). That verification
-- step is not built here — see the app's privacy policy, which says so
-- plainly rather than implying more than this actually does.
-- =============================================================================

alter table students add column if not exists is_minor boolean default false;
alter table students add column if not exists parent_guardian_name text;
alter table students add column if not exists parent_guardian_contact text;
alter table students add column if not exists parental_consent_given_at timestamptz;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text := new.raw_user_meta_data->>'role';
  v_effective_role text := coalesce(nullif(new.raw_user_meta_data->>'role', ''), 'student');
  v_join_mode text := new.raw_user_meta_data->>'join_mode';
  v_coach_id uuid;
  v_national_qualified boolean;
  v_lane_reservation boolean;
  v_gst_percent numeric;
  v_specializations text[];
  v_teaching_disciplines text[];
  v_is_minor boolean;
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
  begin
    v_is_minor := coalesce(nullif(new.raw_user_meta_data->>'is_minor', '')::boolean, false);
  exception when others then
    v_is_minor := false;
  end;

  insert into public.profiles (id, role, name)
  values (new.id, v_effective_role, coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;

  if v_effective_role = 'student' then
    insert into public.students (
      id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified,
      nrai_shooter_id, nrai_email, academy_name, is_minor, parent_guardian_name, parent_guardian_contact,
      parental_consent_given_at
    )
    values (
      new.id, coalesce(new.raw_user_meta_data->>'name', ''), new.raw_user_meta_data->>'phone', new.email,
      coalesce(nullif(new.raw_user_meta_data->>'category', ''), 'Air Rifle 10m'),
      coalesce(nullif(new.raw_user_meta_data->>'shooter_category', ''), 'ISSF'),
      new.raw_user_meta_data->>'coach_name', v_coach_id, v_national_qualified,
      new.raw_user_meta_data->>'nrai_shooter_id', new.raw_user_meta_data->>'nrai_email', new.raw_user_meta_data->>'academy_name',
      v_is_minor, new.raw_user_meta_data->>'parent_guardian_name', new.raw_user_meta_data->>'parent_guardian_contact',
      case when v_is_minor then now() else null end
    )
    on conflict (id) do nothing;
  elsif v_effective_role = 'coach' and v_join_mode is distinct from 'join' then
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
