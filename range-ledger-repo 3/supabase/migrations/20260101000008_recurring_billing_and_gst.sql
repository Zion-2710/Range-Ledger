-- =============================================================================
-- Recurring membership billing + GST support for invoices.
--
-- Two structural additions this depends on:
--  1. `students.next_due_on` — a real `date` column. The existing `due_date`
--     text field ("15 Aug", "9 Aug (passed)") is display-only and was never
--     reliable to compute against (no year, inconsistent format) — you
--     can't safely automate anything off it. `next_due_on` is the real
--     source of truth automation runs against; `due_date` stays as-is for
--     display.
--  2. A scheduled job (pg_cron) that runs daily and flips any student whose
--     cycle has lapsed back to DUE — this is what makes billing "recurring"
--     rather than something a human has to remember to do.
-- =============================================================================

alter table students add column if not exists next_due_on date;
alter table coaches add column if not exists academy_gstin text;
alter table coaches add column if not exists gst_percent numeric not null default 0;
alter table invoices add column if not exists subtotal numeric;
alter table invoices add column if not exists gst_percent numeric not null default 0;
alter table invoices add column if not exists gst_amount numeric not null default 0;
alter table invoices add column if not exists academy_gstin text;

-- Backfill next_due_on for existing PAID students so the very first cron
-- run doesn't immediately flip everyone to DUE — gives them a fresh
-- 30-day cycle starting today instead.
update students set next_due_on = current_date + interval '30 days'
where fee_status = 'PAID' and next_due_on is null;

create or replace function public.roll_over_due_memberships()
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  update students
  set fee_status = 'DUE',
      due_date = to_char(next_due_on, 'DD Mon'),
      next_due_on = null
  where fee_status = 'PAID'
    and next_due_on is not null
    and next_due_on <= current_date;
end;
$$;

-- Schedule it. This requires the pg_cron extension. On Supabase this is
-- usually enabled via Database > Extensions in the dashboard (search for
-- "pg_cron") if the CREATE EXTENSION line below doesn't have permission to
-- run directly from the SQL editor — everything above this point still
-- works either way; only the automatic daily trigger depends on it.
create extension if not exists pg_cron with schema extensions;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'roll-over-due-memberships-daily') then
    perform cron.schedule(
      'roll-over-due-memberships-daily',
      '0 3 * * *', -- 3 AM UTC daily
      $job$ select public.roll_over_due_memberships(); $job$
    );
  end if;
end $$;

-- Redefine the signup trigger once more (see migrations 20260101000001-7) to
-- also capture GSTIN / GST rate for coaches.
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
    insert into public.coaches (id, name, specialization, academy_name, academy_address, lane_reservation, academy_upi_id, academy_gstin, gst_percent)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(new.raw_user_meta_data->>'specialization', 'Air Rifle 10m'),
      new.raw_user_meta_data->>'academy_name',
      new.raw_user_meta_data->>'academy_address',
      coalesce((new.raw_user_meta_data->>'lane_reservation')::boolean, false),
      new.raw_user_meta_data->>'academy_upi_id',
      nullif(new.raw_user_meta_data->>'academy_gstin', ''),
      coalesce(nullif(new.raw_user_meta_data->>'gst_percent', '')::numeric, 0)
    )
    on conflict (id) do nothing;
  end if;

  return new;
end;
$$;
