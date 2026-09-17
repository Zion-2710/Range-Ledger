-- =============================================================================
-- Capture the email a student uses for their NRAI / My NRAI account,
-- alongside their Shooter ID (now required at signup).
-- =============================================================================

alter table students add column if not exists nrai_email text;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text := new.raw_user_meta_data->>'role';
  v_coach_id uuid;
begin
  insert into public.profiles (id, role, name)
  values (new.id, coalesce(v_role, 'student'), coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;

  if v_role = 'student' then
    begin
      v_coach_id := nullif(new.raw_user_meta_data->>'coach_id', '')::uuid;
    exception when others then
      v_coach_id := null;
    end;

    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified, nrai_shooter_id, nrai_email)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      new.raw_user_meta_data->>'phone',
      new.email,
      coalesce(new.raw_user_meta_data->>'category', 'Air Rifle 10m'),
      coalesce(new.raw_user_meta_data->>'shooter_category', 'ISSF'),
      new.raw_user_meta_data->>'coach_name',
      v_coach_id,
      coalesce((new.raw_user_meta_data->>'national_qualified')::boolean, false),
      new.raw_user_meta_data->>'nrai_shooter_id',
      new.raw_user_meta_data->>'nrai_email'
    )
    on conflict (id) do nothing;
  elsif v_role = 'coach' then
    insert into public.coaches (id, name, specialization, academy_name, academy_address, lane_reservation, academy_upi_id)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(new.raw_user_meta_data->>'specialization', 'Air Rifle 10m'),
      new.raw_user_meta_data->>'academy_name',
      new.raw_user_meta_data->>'academy_address',
      coalesce((new.raw_user_meta_data->>'lane_reservation')::boolean, false),
      new.raw_user_meta_data->>'academy_upi_id'
    )
    on conflict (id) do nothing;
  end if;

  return new;
end;
$$;
