-- =============================================================================
-- Real UPI/Google Pay deep-linking (student pays via their own UPI app,
-- coach confirms receipt before the invoice is issued), and capturing each
-- student's official NRAI Shooter ID at signup.
-- =============================================================================

-- Where the coach's academy actually receives payment.
alter table coaches add column if not exists academy_upi_id text;

-- Which method a student's payment is currently awaiting confirmation for
-- (UPI, Google Pay, or Cash) — set the moment they initiate payment, read
-- by the coach/admin confirmation step so the invoice records the right
-- method and the button can say what it's confirming.
alter table students add column if not exists pending_method text;

-- The student's own NRAI Shooter ID (self-reported — they look it up on
-- thenrai.org themselves, we never touch NRAI's systems directly).
alter table students add column if not exists nrai_shooter_id text;

-- Carried onto the invoice so it's on the receipt too.
alter table invoices add column if not exists shooter_id text;

-- Redefine the signup trigger again (see migrations 20260101000001-3) to
-- also capture the new fields.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare
  v_role text := new.raw_user_meta_data->>'role';
begin
  insert into public.profiles (id, role, name)
  values (new.id, coalesce(v_role, 'student'), coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;

  if v_role = 'student' then
    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, national_qualified, nrai_shooter_id)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      new.raw_user_meta_data->>'phone',
      new.email,
      coalesce(new.raw_user_meta_data->>'category', 'Air Rifle 10m'),
      coalesce(new.raw_user_meta_data->>'shooter_category', 'ISSF'),
      new.raw_user_meta_data->>'coach_name',
      coalesce((new.raw_user_meta_data->>'national_qualified')::boolean, false),
      new.raw_user_meta_data->>'nrai_shooter_id'
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
