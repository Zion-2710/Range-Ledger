-- =============================================================================
-- Fix: auto-create profiles/students/coaches rows on signup via a trigger,
-- instead of relying on the client to insert them after signUp() succeeds.
--
-- Why: if your Supabase project requires email confirmation, signUp() does
-- not return an active session until the user clicks the confirmation link.
-- The app's client-side insert was only attempted when a session existed,
-- so on projects with confirmation ON, the students/coaches row was never
-- created — the auth user existed, but their name/phone/etc never made it
-- into the database. A trigger on auth.users fires immediately regardless
-- of confirmation status, so this can no longer be skipped.
-- =============================================================================

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
    insert into public.students (id, name, phone, email, category, shooter_category)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      new.raw_user_meta_data->>'phone',
      new.email,
      coalesce(new.raw_user_meta_data->>'category', 'Air Rifle 10m'),
      coalesce(new.raw_user_meta_data->>'shooter_category', 'ISSF')
    )
    on conflict (id) do nothing;
  elsif v_role = 'coach' then
    insert into public.coaches (id, name, specialization)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(new.raw_user_meta_data->>'specialization', 'Air Rifle 10m')
    )
    on conflict (id) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- =============================================================================
-- One-time backfill: if you already have test accounts created before this
-- fix (visible in Authentication > Users but missing from the students/
-- coaches tables), this fills them in from what auth.users has on record.
-- Safe to run even if there's nothing to backfill.
-- =============================================================================
insert into public.profiles (id, role, name)
select u.id, coalesce(u.raw_user_meta_data->>'role', 'student'), coalesce(u.raw_user_meta_data->>'name', '')
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;

insert into public.students (id, name, phone, email, category, shooter_category)
select u.id, coalesce(u.raw_user_meta_data->>'name', ''), u.raw_user_meta_data->>'phone', u.email,
       coalesce(u.raw_user_meta_data->>'category', 'Air Rifle 10m'), coalesce(u.raw_user_meta_data->>'shooter_category', 'ISSF')
from auth.users u
join public.profiles p on p.id = u.id and p.role = 'student'
left join public.students s on s.id = u.id
where s.id is null;

insert into public.coaches (id, name, specialization)
select u.id, coalesce(u.raw_user_meta_data->>'name', ''), coalesce(u.raw_user_meta_data->>'specialization', 'Air Rifle 10m')
from auth.users u
join public.profiles p on p.id = u.id and p.role = 'coach'
left join public.coaches c on c.id = u.id
where c.id is null;
