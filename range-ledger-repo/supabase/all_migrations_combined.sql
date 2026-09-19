-- =============================================================================
-- Range Ledger — combined migrations, safe to run in one pass
-- Every statement in here uses IF NOT EXISTS / CREATE OR REPLACE / DROP...IF
-- EXISTS patterns, so running this is safe even if some of these were already
-- applied individually before — nothing will error out as 'already exists'.
-- =============================================================================


-- =============================================================================
-- FROM: 20260101000000_initial_schema.sql
-- =============================================================================
-- =============================================================================
-- Range Ledger — Supabase schema
-- Run this in your Supabase project's SQL editor (Database > SQL Editor).
-- Auth (email/password) is handled by Supabase itself — this just adds the
-- app's own tables on top of auth.users, plus row-level security policies.
-- =============================================================================

-- One row per signed-up user. Created by the app right after signUp().
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('student','coach','admin')),
  name text not null,
  created_at timestamptz default now()
);

-- Student-specific data. id = the student's own auth user id.
create table if not exists students (
  id uuid primary key references profiles(id) on delete cascade,
  name text not null,
  phone text,
  email text,
  category text not null,              -- 'Air Rifle 10m' | 'Air Pistol 10m'
  shooter_category text not null,      -- 'ISSF' | 'NR'
  batch text default 'Evening · 5–7 PM',
  coach_name text,
  photo_url text,
  attendance int default 0,
  fee_status text default 'DUE',       -- PAID | DUE | OVERDUE | CASH_PENDING
  due_date text default '15 Aug',
  national_qualified boolean default false,
  joined text default to_char(now(), 'Mon YYYY'),
  created_at timestamptz default now()
);

-- Coach-specific data. id = the coach's own auth user id.
create table if not exists coaches (
  id uuid primary key references profiles(id) on delete cascade,
  name text not null,
  specialization text not null,        -- 'Air Rifle 10m' | 'Air Pistol 10m'
  created_at timestamptz default now()
);

-- One row per logged practice/match session score.
create table if not exists match_scores (
  id bigint generated always as identity primary key,
  student_id uuid not null references students(id) on delete cascade,
  shots int not null,                  -- 10 | 20 | 30 | 40 | 60
  mode text not null,                  -- 'integer' | 'decimal'
  session_label text not null,
  score numeric not null,
  created_at timestamptz default now()
);

-- Attendance mark → coach approval flow.
create table if not exists attendance_requests (
  id bigint generated always as identity primary key,
  student_id uuid not null references students(id) on delete cascade,
  requested_date text not null,
  status text not null default 'PENDING',  -- PENDING | APPROVED | REJECTED
  created_at timestamptz default now()
);

-- Match calendar reminders, visible to everyone in the academy.
create table if not exists reminders (
  id bigint generated always as identity primary key,
  title text not null,
  date date not null,
  type text not null,                  -- Practice Match | State | North Zone | India Open | National Competition
  venue text,
  notes text,
  created_by uuid references profiles(id),
  created_at timestamptz default now()
);

-- Payment records / invoices.
create table if not exists invoices (
  id bigint generated always as identity primary key,
  invoice_number text not null,
  student_id uuid not null references students(id) on delete cascade,
  student_name text,
  email text,
  category text,
  amount numeric,
  method text,                         -- UPI | Google Pay | Cash
  paid_at timestamptz default now()
);

-- =============================================================================
-- Row Level Security
-- These are intentionally permissive for reads (it's a small internal academy
-- app — coaches/admins need to see everyone) and stricter for writes. Tighten
-- as needed for your real deployment; this is a working starting point, not a
-- guarantee.
-- =============================================================================

alter table profiles enable row level security;
alter table students enable row level security;
alter table coaches enable row level security;
alter table match_scores enable row level security;
alter table attendance_requests enable row level security;
alter table reminders enable row level security;
alter table invoices enable row level security;

-- Any signed-in user can read any profile/student/coach row (needed so
-- coaches and admin can see the roster). Only the owner can write their own.
drop policy if exists "profiles readable by authenticated" on profiles;
create policy "profiles readable by authenticated" on profiles for select using (auth.role() = 'authenticated');
drop policy if exists "profiles insert own" on profiles;
create policy "profiles insert own" on profiles for insert with check (auth.uid() = id);
drop policy if exists "profiles update own" on profiles;
create policy "profiles update own" on profiles for update using (auth.uid() = id);

drop policy if exists "students readable by authenticated" on students;
create policy "students readable by authenticated" on students for select using (auth.role() = 'authenticated');
drop policy if exists "students insert own" on students;
create policy "students insert own" on students for insert with check (auth.uid() = id);
drop policy if exists "students update own or staff" on students;
create policy "students update own or staff" on students for update using (
  auth.uid() = id
  or exists (select 1 from profiles p where p.id = auth.uid() and p.role in ('coach','admin'))
);

drop policy if exists "coaches readable by authenticated" on coaches;
create policy "coaches readable by authenticated" on coaches for select using (auth.role() = 'authenticated');
drop policy if exists "coaches insert own" on coaches;
create policy "coaches insert own" on coaches for insert with check (auth.uid() = id);

drop policy if exists "match_scores readable by authenticated" on match_scores;
create policy "match_scores readable by authenticated" on match_scores for select using (auth.role() = 'authenticated');
drop policy if exists "match_scores insert own student" on match_scores;
create policy "match_scores insert own student" on match_scores for insert with check (
  student_id = auth.uid()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.role in ('coach','admin'))
);

drop policy if exists "attendance readable by authenticated" on attendance_requests;
create policy "attendance readable by authenticated" on attendance_requests for select using (auth.role() = 'authenticated');
drop policy if exists "attendance insert own student" on attendance_requests;
create policy "attendance insert own student" on attendance_requests for insert with check (student_id = auth.uid());
drop policy if exists "attendance update by staff" on attendance_requests;
create policy "attendance update by staff" on attendance_requests for update using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role in ('coach','admin'))
);

drop policy if exists "reminders readable by authenticated" on reminders;
create policy "reminders readable by authenticated" on reminders for select using (auth.role() = 'authenticated');
drop policy if exists "reminders insert by authenticated" on reminders;
create policy "reminders insert by authenticated" on reminders for insert with check (auth.role() = 'authenticated');
drop policy if exists "reminders delete by authenticated" on reminders;
create policy "reminders delete by authenticated" on reminders for delete using (auth.role() = 'authenticated');

drop policy if exists "invoices readable by authenticated" on invoices;
create policy "invoices readable by authenticated" on invoices for select using (auth.role() = 'authenticated');
drop policy if exists "invoices insert by authenticated" on invoices;
create policy "invoices insert by authenticated" on invoices for insert with check (auth.role() = 'authenticated');

-- =============================================================================
-- Storage bucket for passport photos (create via Storage tab, or here):
-- =============================================================================
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true)
on conflict (id) do nothing;

drop policy if exists "avatar images publicly readable" on storage.objects;
create policy "avatar images publicly readable" on storage.objects for select using (bucket_id = 'avatars');
drop policy if exists "authenticated users can upload avatars" on storage.objects;
create policy "authenticated users can upload avatars" on storage.objects for insert with check (
  bucket_id = 'avatars' and auth.role() = 'authenticated'
);


-- =============================================================================
-- FROM: 20260101000001_auto_create_profile_trigger.sql
-- =============================================================================
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


-- =============================================================================
-- FROM: 20260101000002_inventory_and_branding.sql
-- =============================================================================
-- =============================================================================
-- Academy branding (per coach) + inventory tracking, feeding into invoices.
-- =============================================================================

alter table coaches add column if not exists academy_name text;
alter table coaches add column if not exists academy_address text;
alter table coaches add column if not exists lane_reservation boolean default false;

-- Inventory owned by a coach (pellets, targets, rented equipment, etc.)
create table if not exists inventory_items (
  id bigint generated always as identity primary key,
  coach_id uuid not null references coaches(id) on delete cascade,
  name text not null,
  quantity int not null default 0,
  unit_price numeric default 0,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- An item handed to a student, pending inclusion on their next invoice.
create table if not exists inventory_issues (
  id bigint generated always as identity primary key,
  coach_id uuid not null references coaches(id) on delete cascade,
  student_id uuid not null references students(id) on delete cascade,
  item_name text not null,
  quantity int not null,
  unit_price numeric default 0,
  invoiced boolean not null default false,
  invoice_id bigint references invoices(id),
  issued_at timestamptz default now()
);

-- Invoices grow itemized line items + the issuing academy's branding, snapshotted
-- at the time of payment (so old invoices don't change if a coach edits their
-- academy details later).
alter table invoices add column if not exists items jsonb default '[]'::jsonb;
alter table invoices add column if not exists academy_name text;
alter table invoices add column if not exists academy_address text;
alter table invoices add column if not exists batch text;
alter table invoices add column if not exists lane text;

alter table inventory_items enable row level security;
alter table inventory_issues enable row level security;

drop policy if exists "inventory readable by authenticated" on inventory_items;
create policy "inventory readable by authenticated" on inventory_items for select using (auth.role() = 'authenticated');
drop policy if exists "inventory insert by owning coach" on inventory_items;
create policy "inventory insert by owning coach" on inventory_items for insert with check (coach_id = auth.uid());
drop policy if exists "inventory update by owning coach" on inventory_items;
create policy "inventory update by owning coach" on inventory_items for update using (coach_id = auth.uid());
drop policy if exists "inventory delete by owning coach" on inventory_items;
create policy "inventory delete by owning coach" on inventory_items for delete using (coach_id = auth.uid());

drop policy if exists "issues readable by authenticated" on inventory_issues;
create policy "issues readable by authenticated" on inventory_issues for select using (auth.role() = 'authenticated');
drop policy if exists "issues insert by owning coach" on inventory_issues;
create policy "issues insert by owning coach" on inventory_issues for insert with check (coach_id = auth.uid());
-- Update is needed by whichever side triggers invoicing: the student (paying
-- online themselves) or any staff member (a coach confirming their own
-- issue, or admin confirming a cash payment on any coach's behalf).
drop policy if exists "issues update by student or coach" on inventory_issues;
create policy "issues update by student or coach" on inventory_issues for update using (
  student_id = auth.uid()
  or coach_id = auth.uid()
  or exists (select 1 from profiles p where p.id = auth.uid() and p.role in ('coach','admin'))
);

-- =============================================================================
-- Update the signup trigger to also capture academy name/address/lane
-- reservation for coaches (in addition to what migration 1 already handles).
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
    insert into public.coaches (id, name, specialization, academy_name, academy_address, lane_reservation)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(new.raw_user_meta_data->>'specialization', 'Air Rifle 10m'),
      new.raw_user_meta_data->>'academy_name',
      new.raw_user_meta_data->>'academy_address',
      coalesce((new.raw_user_meta_data->>'lane_reservation')::boolean, false)
    )
    on conflict (id) do nothing;
  end if;

  return new;
end;
$$;


-- =============================================================================
-- FROM: 20260101000003_coach_name_and_score_precision.sql
-- =============================================================================
-- =============================================================================
-- Capture the student's coach name and (for ISSF shooters) their own
-- reported Nationals-qualification status at signup, and fix decimal
-- precision on match scores.
-- =============================================================================

alter table students add column if not exists coach_name text;

-- Match scores are only ever stored to one decimal place by the app
-- (whole scoring or 10.9-per-shot decimal scoring). A bare `numeric` column
-- has no fixed scale, which is where Supabase's Table Editor grid view can
-- render inconsistently — pinning the scale makes it display reliably and
-- matches how the app actually uses it.
alter table match_scores alter column score type numeric(7,1);

-- Redefine the signup trigger again (see migrations 20260101000001 and
-- 20260101000002) to also capture coach_name for students, and to set
-- national_qualified from their own signup answer instead of always
-- defaulting to false.
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
    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, national_qualified)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      new.raw_user_meta_data->>'phone',
      new.email,
      coalesce(new.raw_user_meta_data->>'category', 'Air Rifle 10m'),
      coalesce(new.raw_user_meta_data->>'shooter_category', 'ISSF'),
      new.raw_user_meta_data->>'coach_name',
      coalesce((new.raw_user_meta_data->>'national_qualified')::boolean, false)
    )
    on conflict (id) do nothing;
  elsif v_role = 'coach' then
    insert into public.coaches (id, name, specialization, academy_name, academy_address, lane_reservation)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(new.raw_user_meta_data->>'specialization', 'Air Rifle 10m'),
      new.raw_user_meta_data->>'academy_name',
      new.raw_user_meta_data->>'academy_address',
      coalesce((new.raw_user_meta_data->>'lane_reservation')::boolean, false)
    )
    on conflict (id) do nothing;
  end if;

  return new;
end;
$$;


-- =============================================================================
-- FROM: 20260101000004_upi_payments_and_shooter_id.sql
-- =============================================================================
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


-- =============================================================================
-- FROM: 20260101000005_inventory_requests_and_realtime.sql
-- =============================================================================
-- =============================================================================
-- Let students request items from their coach's inventory (not just have
-- items pushed to them), and enable Realtime so changes made in one tab
-- (e.g. a student marking attendance, or a coach confirming a payment)
-- show up live in another tab without a manual refresh.
-- =============================================================================

-- Tracks whether an issue is just a student's request awaiting approval,
-- an approved/given item, or a declined request. Existing rows (all
-- created by the coach's direct "give to student" flow) default to
-- 'issued', which is correct for them.
alter table inventory_issues add column if not exists status text not null default 'issued';

-- Students can now create their own request rows (status='issued' is only
-- ever set by the coach approving one — enforced in the app, not RLS, to
-- keep this simple).
drop policy if exists "issues insert by requesting student" on inventory_issues;
create policy "issues insert by requesting student" on inventory_issues for insert with check (student_id = auth.uid());

-- Realtime: add each table to the publication only if it isn't already
-- there, so this migration is safe to rerun.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'attendance_requests') then
    alter publication supabase_realtime add table public.attendance_requests;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_issues') then
    alter publication supabase_realtime add table public.inventory_issues;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'inventory_items') then
    alter publication supabase_realtime add table public.inventory_items;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'students') then
    alter publication supabase_realtime add table public.students;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'invoices') then
    alter publication supabase_realtime add table public.invoices;
  end if;
end $$;


-- =============================================================================
-- FROM: 20260101000006_multi_tenant_isolation.sql
-- =============================================================================
-- =============================================================================
-- Multi-tenant isolation.
--
-- Until now, "which academy does this student belong to" was only implied
-- by matching weapon category text against any coach teaching that weapon —
-- which means a student (or coach) at one academy could see another
-- academy's roster, invoices, and scores, since every RLS policy so far
-- just checked auth.role() = 'authenticated' with no tenant boundary.
--
-- This migration adds a real coach_id relationship on students (the actual
-- source of truth for "which academy"), and rewrites every policy to scope
-- by it. Two roles are treated as spanning all tenants on purpose: 'admin'
-- (platform-wide oversight — reconsider this if you want per-academy admins
-- instead) and shared content like the match reminders calendar, which is
-- genuinely cross-academy (a State Championship isn't owned by one coach).
-- =============================================================================

-- The real tenant relationship. coach_name stays as-is for display/history;
-- coach_id is what authorization now runs on.
alter table students add column if not exists coach_id uuid references coaches(id);

-- Best-effort backfill for existing rows: match on name + weapon category.
-- This is a guess for data created before this migration — if a student's
-- coach_id is still null afterward, they didn't match anything and should
-- be reassigned manually (e.g. via the Table Editor).
update students s
set coach_id = c.id
from coaches c
where s.coach_id is null
  and s.coach_name is not null
  and lower(trim(s.coach_name)) = lower(trim(c.name))
  and s.category = c.specialization;

-- A public, minimal directory so a prospective student can pick their real
-- coach at signup — before they have an account or session. Deliberately
-- excludes sensitive fields (academy_upi_id, academy_address) that the
-- full `coaches` table now restricts to tenant members only.
create or replace view public.coach_directory as
  select id, name, academy_name, specialization from coaches;
grant select on public.coach_directory to anon, authenticated;

-- =============================================================================
-- Helper functions (security definer so they can check role/tenant
-- membership without getting tangled in the RLS of the tables they query).
-- =============================================================================
create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- True if the caller is the student themself, that student's own coach, or
-- an admin. Reused by every table that has a student_id column, so the
-- "who can see/touch this student's data" rule is defined in exactly one
-- place instead of copy-pasted (and potentially drifting) across policies.
create or replace function public.student_belongs_to_caller(sid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select
    exists (
      select 1 from students s
      where s.id = sid and (s.id = auth.uid() or s.coach_id = auth.uid())
    )
    or public.is_admin();
$$;

-- Redefine the signup trigger once more to set coach_id (selected from the
-- coach_directory dropdown) instead of only free-text coach_name.
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

    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified, nrai_shooter_id)
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

-- =============================================================================
-- Tenant-scoped RLS. Every "readable/writable by authenticated" policy from
-- earlier migrations is replaced here.
-- =============================================================================

drop policy if exists "students readable by authenticated" on students;
create policy "students readable by tenant" on students for select using (
  id = auth.uid() or coach_id = auth.uid() or is_admin()
);
drop policy if exists "students update own or staff" on students;
create policy "students update by tenant" on students for update using (
  id = auth.uid() or coach_id = auth.uid() or is_admin()
);
-- insert policy ("students insert own") is unchanged — self-insert at signup.

drop policy if exists "coaches readable by authenticated" on coaches;
create policy "coaches readable by tenant" on coaches for select using (
  id = auth.uid() or is_admin()
  or exists (select 1 from students s where s.coach_id = coaches.id and s.id = auth.uid())
);
-- insert policy ("coaches insert own") is unchanged.

drop policy if exists "match_scores readable by authenticated" on match_scores;
create policy "match_scores readable by tenant" on match_scores for select using (
  student_belongs_to_caller(student_id)
);
drop policy if exists "match_scores insert own student" on match_scores;
create policy "match_scores insert by tenant" on match_scores for insert with check (
  student_belongs_to_caller(student_id)
);

drop policy if exists "attendance readable by authenticated" on attendance_requests;
create policy "attendance readable by tenant" on attendance_requests for select using (
  student_belongs_to_caller(student_id)
);
-- insert policy ("attendance insert own student") is unchanged — a student
-- can only ever mark their own attendance.
drop policy if exists "attendance update by staff" on attendance_requests;
create policy "attendance update by tenant staff" on attendance_requests for update using (
  student_belongs_to_caller(student_id)
);

drop policy if exists "invoices readable by authenticated" on invoices;
create policy "invoices readable by tenant" on invoices for select using (
  student_belongs_to_caller(student_id)
);
drop policy if exists "invoices insert by authenticated" on invoices;
create policy "invoices insert by tenant" on invoices for insert with check (
  student_belongs_to_caller(student_id)
);

drop policy if exists "inventory readable by authenticated" on inventory_items;
create policy "inventory readable by tenant" on inventory_items for select using (
  coach_id = auth.uid() or is_admin()
  or exists (select 1 from students s where s.coach_id = inventory_items.coach_id and s.id = auth.uid())
);
-- insert/update-by-owning-coach policies are unchanged (already coach_id-scoped).

drop policy if exists "issues readable by authenticated" on inventory_issues;
create policy "issues readable by tenant" on inventory_issues for select using (
  student_belongs_to_caller(student_id)
);
drop policy if exists "issues insert by staff" on inventory_issues;
create policy "issues insert by tenant staff" on inventory_issues for insert with check (
  coach_id = auth.uid() or is_admin()
);
-- "issues insert by requesting student" (student_id = auth.uid()) is unchanged.
drop policy if exists "issues update by student or coach" on inventory_issues;
create policy "issues update by tenant" on inventory_issues for update using (
  student_belongs_to_caller(student_id)
);

-- reminders and profiles are intentionally left as-is: reminders are shared
-- match-calendar content (a State Championship isn't one academy's data),
-- and profiles only expose name + role, used internally for role checks.

-- =============================================================================
-- Storage: avatars. Previously any authenticated user could upload to *any*
-- path in this bucket, including overwriting someone else's photo — these
-- policies restrict uploads/updates to a path the caller's own uid owns
-- (the app already uploads to "<user id>/filename", so this matches that
-- convention without requiring any client-side change).
-- =============================================================================
drop policy if exists "authenticated users can upload avatars" on storage.objects;
drop policy if exists "users can upload own avatar" on storage.objects;
create policy "users can upload own avatar" on storage.objects for insert with check (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
);
drop policy if exists "users can update own avatar" on storage.objects;
create policy "users can update own avatar" on storage.objects for update using (
  bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
);
-- "avatar images publicly readable" (select) is unchanged — read access
-- stays public since the photo URLs aren't enumerable without already
-- knowing them, same as a typical public object-storage bucket.


-- =============================================================================
-- FROM: 20260101000007_nrai_email.sql
-- =============================================================================
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


-- =============================================================================
-- FROM: 20260101000008_recurring_billing_and_gst.sql
-- =============================================================================
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


-- =============================================================================
-- FROM: 20260101000009_fix_signup_trigger.sql
-- =============================================================================
-- =============================================================================
-- Repair migration for "Database error saving new user" on signup.
--
-- That error means the handle_new_user trigger (which fires on every new
-- auth.users row) threw an exception. The trigger has been redefined 7
-- times across migrations 0001–0008, each adding new fields — if any one
-- of those was skipped, run out of order, or failed partway, the LATEST
-- trigger logic can end up referencing a column that doesn't actually
-- exist yet in your database, which fails every single signup with this
-- generic error.
--
-- This migration is safe to run regardless of which earlier migrations
-- you've actually applied: every column below uses "add column if not
-- exists" (so nothing breaks if it's already there), and the trigger is
-- rewritten once more to be defensive against bad/missing metadata on
-- every field, not just coach_id.
-- =============================================================================

alter table students add column if not exists coach_name text;
alter table students add column if not exists coach_id uuid references coaches(id);
alter table students add column if not exists national_qualified boolean not null default false;
alter table students add column if not exists nrai_shooter_id text;
alter table students add column if not exists nrai_email text;
alter table students add column if not exists next_due_on date;

alter table coaches add column if not exists academy_name text;
alter table coaches add column if not exists academy_address text;
alter table coaches add column if not exists lane_reservation boolean not null default false;
alter table coaches add column if not exists academy_upi_id text;
alter table coaches add column if not exists academy_gstin text;
alter table coaches add column if not exists gst_percent numeric not null default 0;

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
begin
  -- Every cast below is wrapped defensively: if a metadata value is
  -- missing, empty, or malformed in any way, fall back to a safe default
  -- instead of throwing and failing the whole signup.
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
    insert into public.coaches (id, name, specialization, academy_name, academy_address, lane_reservation, academy_upi_id, academy_gstin, gst_percent)
    values (
      new.id,
      coalesce(new.raw_user_meta_data->>'name', ''),
      coalesce(nullif(new.raw_user_meta_data->>'specialization', ''), 'Air Rifle 10m'),
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
  -- Last resort: log what actually went wrong instead of just failing
  -- silently with the generic "Database error saving new user" message.
  -- Check Supabase's Postgres logs (Logs & Analytics > Postgres Logs) for
  -- a line starting with "handle_new_user failed:" if signups still fail
  -- after this migration — that will show the real underlying reason.
  raise warning 'handle_new_user failed: % — %', sqlstate, sqlerrm;
  return new;
end;
$$;


-- =============================================================================
-- FROM: 20260101000010_qualification_standards.sql
-- =============================================================================
-- =============================================================================
-- Sports Federation Compliance & Qualification Standards.
--
-- Stores benchmark cutoff scores per tier (State Championship, Pre-National
-- / MQS, National Championship, Team Trials), per weapon category, shot
-- count, and scoring mode. Admin-managed since these represent official
-- federation standards that should be consistent platform-wide, not set
-- per-coach.
--
-- IMPORTANT: the seed values below are illustrative placeholders only, not
-- verified official NRAI/ISSF figures — real qualifying scores vary by age
-- category, gender, and are revised over time. An admin should replace
-- these with the federation's actual currently-published standards before
-- relying on this for real qualification decisions.
-- =============================================================================

create table if not exists qualification_standards (
  id bigint generated always as identity primary key,
  category text not null,        -- 'Air Rifle 10m' | 'Air Pistol 10m'
  shots int not null,            -- 10 | 20 | 30 | 40 | 60
  mode text not null,            -- 'integer' | 'decimal'
  tier text not null,            -- 'State Championship' | 'Pre-National / MQS' | 'National Championship' | 'Team Trials'
  cutoff_score numeric not null,
  created_at timestamptz default now()
);

alter table qualification_standards enable row level security;

drop policy if exists "standards readable by authenticated" on qualification_standards;
create policy "standards readable by authenticated" on qualification_standards for select using (auth.role() = 'authenticated');

drop policy if exists "standards managed by admin" on qualification_standards;
create policy "standards managed by admin" on qualification_standards for all using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
) with check (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
);

-- Illustrative starting defaults for 60-shot events (the most common
-- qualification benchmark distance) in decimal (10.9/shot) scoring, so the
-- module has something to demonstrate against immediately. Replace these.
insert into qualification_standards (category, shots, mode, tier, cutoff_score)
select * from (values
  ('Air Rifle 10m', 60, 'decimal', 'State Championship', 600.0),
  ('Air Rifle 10m', 60, 'decimal', 'Pre-National / MQS', 615.0),
  ('Air Rifle 10m', 60, 'decimal', 'National Championship', 625.0),
  ('Air Rifle 10m', 60, 'decimal', 'Team Trials', 630.0),
  ('Air Pistol 10m', 60, 'decimal', 'State Championship', 560.0),
  ('Air Pistol 10m', 60, 'decimal', 'Pre-National / MQS', 570.0),
  ('Air Pistol 10m', 60, 'decimal', 'National Championship', 575.0),
  ('Air Pistol 10m', 60, 'decimal', 'Team Trials', 580.0)
) as seed(category, shots, mode, tier, cutoff_score)
where not exists (select 1 from qualification_standards);


-- =============================================================================
-- FROM: 20260101000011_notification_hub.sql
-- =============================================================================
-- =============================================================================
-- Notification Hub: reusable message templates + tenant-scoped broadcasts.
--
-- Three delivery channels are recorded on every broadcast:
--   'app'      — shown in the recipient's own dashboard immediately. The
--                only channel that's fully automatic with no external
--                dependency or manual step.
--   'whatsapp' — the app generates one personalized wa.me click-to-chat
--                link per recipient with a phone number. WhatsApp's own
--                click-to-chat only opens one contact at a time — true
--                bulk sending needs a paid WhatsApp Business API account,
--                which isn't something this migration or the app can wire
--                up without your own business account and credentials.
--   'sms'      — recorded as an integration point only. Actually sending
--                requires a paid SMS provider (Twilio, MSG91, etc.) and a
--                backend (a Supabase Edge Function is the natural fit) to
--                hold the provider's API key safely — that key must never
--                live in client-side code. This migration and the app
--                structure the data for it; wiring the real send call is
--                a separate step once you have provider credentials.
-- =============================================================================

create table if not exists notification_templates (
  id bigint generated always as identity primary key,
  title text not null,
  body text not null, -- supports {name}, {category}, {academy_name} placeholders
  created_by uuid,
  created_at timestamptz default now()
);

create table if not exists notification_broadcasts (
  id bigint generated always as identity primary key,
  message text not null,
  audience_role text not null default 'student',   -- 'student' | 'coach' | 'all'
  audience_category text,                          -- null = all weapon categories
  audience_fee_status text,                        -- null = any fee status
  target_coach_id uuid references coaches(id),      -- null = platform-wide (admin only); a coach's own sends are always scoped to their own id
  channel text not null default 'app',             -- 'app' | 'whatsapp' | 'sms'
  recipient_count int not null default 0,
  sent_by uuid,
  sent_by_name text,
  created_at timestamptz default now()
);

alter table notification_templates enable row level security;
alter table notification_broadcasts enable row level security;

drop policy if exists "templates readable by staff" on notification_templates;
create policy "templates readable by staff" on notification_templates for select using (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role in ('coach', 'admin'))
);
drop policy if exists "templates insert by staff" on notification_templates;
create policy "templates insert by staff" on notification_templates for insert with check (
  exists (select 1 from profiles p where p.id = auth.uid() and p.role in ('coach', 'admin'))
);
drop policy if exists "templates delete by owner or admin" on notification_templates;
create policy "templates delete by owner or admin" on notification_templates for delete using (
  created_by = auth.uid() or is_admin()
);

-- A coach can only ever broadcast to their own roster (target_coach_id =
-- their own id) — this keeps the Notification Hub consistent with the
-- multi-tenant isolation already enforced everywhere else. Only admin can
-- send a truly platform-wide broadcast (target_coach_id null).
drop policy if exists "broadcasts insert by staff" on notification_broadcasts;
create policy "broadcasts insert by staff" on notification_broadcasts for insert with check (
  (target_coach_id = auth.uid() and exists (select 1 from coaches c where c.id = auth.uid()))
  or (target_coach_id is null and is_admin())
);

-- Visible to: whoever sent it, admin (oversight), or anyone it was actually
-- addressed to based on their own role/category/fee-status/tenant.
drop policy if exists "broadcasts readable by sender and recipients" on notification_broadcasts;
create policy "broadcasts readable by sender and recipients" on notification_broadcasts for select using (
  sent_by = auth.uid()
  or is_admin()
  or exists (
    select 1 from students s where s.id = auth.uid()
      and notification_broadcasts.audience_role in ('all', 'student')
      and (notification_broadcasts.target_coach_id is null or notification_broadcasts.target_coach_id = s.coach_id)
      and (notification_broadcasts.audience_category is null or notification_broadcasts.audience_category = s.category)
      and (notification_broadcasts.audience_fee_status is null or notification_broadcasts.audience_fee_status = s.fee_status)
  )
  or exists (
    select 1 from coaches c where c.id = auth.uid()
      and notification_broadcasts.audience_role in ('all', 'coach')
  )
);

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notification_broadcasts') then
    alter publication supabase_realtime add table public.notification_broadcasts;
  end if;
end $$;


-- =============================================================================
-- FROM: 20260101000012_data_integrity_and_storage_hardening.sql
-- =============================================================================
-- =============================================================================
-- Data integrity constraints + storage hardening.
--
-- Each constraint is added inside its own DO block that checks
-- pg_constraint first -- the same plain pattern already used successfully
-- elsewhere in this project (e.g. the pg_cron job check in migration
-- 20260101000008), avoiding any custom helper function.
-- =============================================================================

alter table coaches add column if not exists gst_percent numeric not null default 0;
alter table coaches add column if not exists academy_gstin text;
alter table invoices add column if not exists subtotal numeric;
alter table invoices add column if not exists gst_percent numeric not null default 0;
alter table invoices add column if not exists gst_amount numeric not null default 0;
alter table students add column if not exists next_due_on date;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_items_quantity_nonneg') then
    alter table inventory_items add constraint inventory_items_quantity_nonneg check (quantity >= 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_items_price_nonneg') then
    alter table inventory_items add constraint inventory_items_price_nonneg check (unit_price >= 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_issues_quantity_positive') then
    alter table inventory_issues add constraint inventory_issues_quantity_positive check (quantity > 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'inventory_issues_unit_price_nonneg') then
    alter table inventory_issues add constraint inventory_issues_unit_price_nonneg check (unit_price >= 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'qualification_standards_cutoff_positive') then
    alter table qualification_standards add constraint qualification_standards_cutoff_positive check (cutoff_score > 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'qualification_standards_shots_positive') then
    alter table qualification_standards add constraint qualification_standards_shots_positive check (shots > 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'coaches_gst_percent_range') then
    alter table coaches add constraint coaches_gst_percent_range check (gst_percent >= 0 and gst_percent <= 100) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_amount_nonneg') then
    alter table invoices add constraint invoices_amount_nonneg check (amount >= 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_gst_percent_range') then
    alter table invoices add constraint invoices_gst_percent_range check (gst_percent >= 0 and gst_percent <= 100) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_gst_amount_nonneg') then
    alter table invoices add constraint invoices_gst_amount_nonneg check (gst_amount >= 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'match_scores_score_nonneg') then
    alter table match_scores add constraint match_scores_score_nonneg check (score >= 0) not valid;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'notification_broadcasts_recipient_count_nonneg') then
    alter table notification_broadcasts add constraint notification_broadcasts_recipient_count_nonneg check (recipient_count >= 0) not valid;
  end if;
end $$;

-- Validate each one now, so a violation from existing bad data shows up
-- here in the SQL editor output rather than staying silently un-checked.
alter table inventory_items validate constraint inventory_items_quantity_nonneg;
alter table inventory_items validate constraint inventory_items_price_nonneg;
alter table inventory_issues validate constraint inventory_issues_quantity_positive;
alter table inventory_issues validate constraint inventory_issues_unit_price_nonneg;
alter table qualification_standards validate constraint qualification_standards_cutoff_positive;
alter table qualification_standards validate constraint qualification_standards_shots_positive;
alter table coaches validate constraint coaches_gst_percent_range;
alter table invoices validate constraint invoices_amount_nonneg;
alter table invoices validate constraint invoices_gst_percent_range;
alter table invoices validate constraint invoices_gst_amount_nonneg;
alter table match_scores validate constraint match_scores_score_nonneg;
alter table notification_broadcasts validate constraint notification_broadcasts_recipient_count_nonneg;

-- =============================================================================
-- Avatars storage: server-side size and type limits.
-- =============================================================================
update storage.buckets
set file_size_limit = 2097152,
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'avatars';


-- =============================================================================
-- FROM: 20260101000013_backfill_missing_profile_rows.sql
-- =============================================================================
-- =============================================================================
-- Repairs accounts left broken by earlier trigger issues: any profile with
-- role='coach' or role='student' that has no matching row in coaches/
-- students respectively (this is exactly what causes "Cannot read
-- properties of null" crashes on login -- the app loads the profile,
-- finds no matching coach/student record, and has nothing to show).
--
-- Rebuilds each missing row from auth.users.raw_user_meta_data, which
-- Supabase keeps permanently from the original signup -- the same source
-- the signup trigger itself reads from, so this produces the same result
-- the trigger should have produced the first time.
-- =============================================================================

insert into coaches (id, name, specialization, academy_name, academy_address, lane_reservation, academy_upi_id, academy_gstin, gst_percent)
select
  p.id,
  coalesce(p.name, u.raw_user_meta_data->>'name', ''),
  coalesce(nullif(u.raw_user_meta_data->>'specialization', ''), 'Air Rifle 10m'),
  u.raw_user_meta_data->>'academy_name',
  u.raw_user_meta_data->>'academy_address',
  coalesce((u.raw_user_meta_data->>'lane_reservation')::boolean, false),
  u.raw_user_meta_data->>'academy_upi_id',
  nullif(u.raw_user_meta_data->>'academy_gstin', ''),
  coalesce(nullif(u.raw_user_meta_data->>'gst_percent', '')::numeric, 0)
from profiles p
join auth.users u on u.id = p.id
where p.role = 'coach'
  and not exists (select 1 from coaches c where c.id = p.id)
on conflict (id) do nothing;

insert into students (id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified, nrai_shooter_id, nrai_email)
select
  p.id,
  coalesce(p.name, u.raw_user_meta_data->>'name', ''),
  u.raw_user_meta_data->>'phone',
  u.email,
  coalesce(nullif(u.raw_user_meta_data->>'category', ''), 'Air Rifle 10m'),
  coalesce(nullif(u.raw_user_meta_data->>'shooter_category', ''), 'ISSF'),
  u.raw_user_meta_data->>'coach_name',
  nullif(u.raw_user_meta_data->>'coach_id', '')::uuid,
  coalesce((u.raw_user_meta_data->>'national_qualified')::boolean, false),
  u.raw_user_meta_data->>'nrai_shooter_id',
  u.raw_user_meta_data->>'nrai_email'
from profiles p
join auth.users u on u.id = p.id
where p.role = 'student'
  and not exists (select 1 from students s where s.id = p.id)
on conflict (id) do nothing;

-- Run this after applying, to confirm nothing is still missing:
--   select p.id, p.role, p.name from profiles p
--   left join coaches c on c.id = p.id and p.role = 'coach'
--   left join students s on s.id = p.id and p.role = 'student'
--   where (p.role = 'coach' and c.id is null) or (p.role = 'student' and s.id is null);
-- An empty result means every account now has its matching row.


-- =============================================================================
-- FROM: 20260101000014_session_names_and_coach_evaluation.sql
-- =============================================================================
-- =============================================================================
-- Two additions to support a richer, shareable progress report:
--  1. An optional descriptive name per logged session (e.g. "Academy
--     Monthly Match #8") alongside the existing auto-generated M1/M2 label.
--  2. A free-text coach evaluation on each student, shown on their
--     progress report when the coach has written one.
-- =============================================================================

alter table match_scores add column if not exists session_name text;
alter table students add column if not exists coach_evaluation text;


-- =============================================================================
-- FROM: 20260101000015_multi_discipline_coaches.sql
-- =============================================================================
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


-- =============================================================================
-- FROM: 20260101000016_shooter_academy_name.sql
-- =============================================================================
-- Captures the shooter's own stated academy name at signup — useful
-- alongside their coach name, especially when their coach hasn't
-- registered on the platform yet and there's no coaches.academy_name to
-- fall back on.
alter table students add column if not exists academy_name text;

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
    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified, nrai_shooter_id, nrai_email, academy_name)
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
      new.raw_user_meta_data->>'nrai_email',
      new.raw_user_meta_data->>'academy_name'
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


-- =============================================================================
-- FROM: 20260101000017_academy_staff_and_invites.sql
-- =============================================================================
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


-- =============================================================================
-- FROM: 20260101000018_staff_role_write_restrictions.sql
-- =============================================================================
-- =============================================================================
-- Fixes a real gap in the previous migration: is_academy_staff_of() checks
-- only "approved," not role — meaning a viewer, who should be read-only,
-- could still insert/update data directly via the API even though the
-- app's own UI hides those buttons for them. Client-side hiding is not a
-- security boundary; RLS is. This adds a role-aware check and applies it
-- to every write policy that a viewer must NOT pass, while leaving read
-- access (which viewers should have) untouched.
-- =============================================================================

create or replace function public.is_academy_editor_of(target_coach_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from academy_staff
    where coach_id = target_coach_id and user_id = auth.uid() and status = 'approved' and role in ('admin', 'editor')
  );
$$;

-- Read-side helper is unchanged (viewers should still see everything an
-- editor sees) — only the write-side checks below are tightened.
create or replace function public.student_belongs_to_editor_caller(sid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select
    exists (
      select 1 from students s
      where s.id = sid and (s.coach_id = auth.uid() or is_academy_editor_of(s.coach_id))
    )
    or public.is_admin();
$$;

drop policy if exists "match_scores insert by tenant" on match_scores;
create policy "match_scores insert by tenant" on match_scores for insert with check (
  student_id = auth.uid() or student_belongs_to_editor_caller(student_id)
);

drop policy if exists "attendance update by tenant staff" on attendance_requests;
create policy "attendance update by tenant staff" on attendance_requests for update using (
  student_belongs_to_editor_caller(student_id)
);

drop policy if exists "invoices insert by tenant" on invoices;
create policy "invoices insert by tenant" on invoices for insert with check (
  student_belongs_to_editor_caller(student_id)
);

drop policy if exists "issues update by tenant" on inventory_issues;
create policy "issues update by tenant" on inventory_issues for update using (
  student_id = auth.uid() or student_belongs_to_editor_caller(student_id)
);

drop policy if exists "issues insert by tenant staff" on inventory_issues;
create policy "issues insert by tenant staff" on inventory_issues for insert with check (
  coach_id = auth.uid() or is_admin() or is_academy_editor_of(coach_id)
);

drop policy if exists "inventory insert by owning coach" on inventory_items;
create policy "inventory insert by owning coach" on inventory_items for insert with check (
  coach_id = auth.uid() or is_academy_editor_of(coach_id)
);
drop policy if exists "inventory update by owning coach" on inventory_items;
create policy "inventory update by owning coach" on inventory_items for update using (
  coach_id = auth.uid() or is_academy_editor_of(coach_id)
);
drop policy if exists "inventory delete by owning coach" on inventory_items;
create policy "inventory delete by owning coach" on inventory_items for delete using (
  coach_id = auth.uid() or is_academy_editor_of(coach_id)
);

drop policy if exists "broadcasts insert by staff" on notification_broadcasts;
create policy "broadcasts insert by staff" on notification_broadcasts for insert with check (
  (target_coach_id = auth.uid() and exists (select 1 from coaches c where c.id = auth.uid()))
  or (target_coach_id is not null and is_academy_editor_of(target_coach_id))
  or (target_coach_id is null and is_admin())
);

-- Students themselves can still update their own row (e.g. photo, coach
-- selection at signup); a viewer just can't update a STUDENT'S row on
-- their behalf, which is what this tightens.
drop policy if exists "students update by tenant" on students;
create policy "students update by tenant" on students for update using (
  id = auth.uid() or coach_id = auth.uid() or is_academy_editor_of(coach_id) or is_admin()
);


-- =============================================================================
-- FROM: 20260101000019_fix_google_signup_role_branch.sql
-- =============================================================================
-- =============================================================================
-- Fixes a real bug: the trigger defaulted profiles.role to 'student' via
-- coalesce(v_role, 'student'), but then branched on the RAW (possibly
-- null) v_role to decide whether to create a students row. For anyone
-- who signs up without our custom metadata attached — a Google sign-up
-- being the main case, since Google doesn't carry a "role" field — v_role
-- is null, so profiles said "student" but no students row was ever
-- created. That produces exactly the "signed in, but your shooter
-- profile hasn't been set up correctly" error. This fix branches on the
-- same coalesced value used for the profile itself, so the two can
-- never disagree.
-- =============================================================================

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
  values (new.id, v_effective_role, coalesce(new.raw_user_meta_data->>'name', ''))
  on conflict (id) do nothing;

  if v_effective_role = 'student' then
    insert into public.students (id, name, phone, email, category, shooter_category, coach_name, coach_id, national_qualified, nrai_shooter_id, nrai_email, academy_name)
    values (
      new.id, coalesce(new.raw_user_meta_data->>'name', ''), new.raw_user_meta_data->>'phone', new.email,
      coalesce(nullif(new.raw_user_meta_data->>'category', ''), 'Air Rifle 10m'),
      coalesce(nullif(new.raw_user_meta_data->>'shooter_category', ''), 'ISSF'),
      new.raw_user_meta_data->>'coach_name', v_coach_id, v_national_qualified,
      new.raw_user_meta_data->>'nrai_shooter_id', new.raw_user_meta_data->>'nrai_email', new.raw_user_meta_data->>'academy_name'
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

-- Backfill: anyone already stuck in this broken state (a profiles row
-- saying 'student' with no matching students row) gets a minimal
-- students row created now, so existing affected accounts recover
-- without needing to re-signup.
insert into public.students (id, name, email, category, shooter_category)
select p.id, coalesce(u.raw_user_meta_data->>'name', ''), u.email, 'Air Rifle 10m', 'ISSF'
from public.profiles p
join auth.users u on u.id = p.id
where p.role = 'student'
  and not exists (select 1 from public.students s where s.id = p.id)
on conflict (id) do nothing;


-- =============================================================================
-- FROM: 20260101000020_parental_consent.sql
-- =============================================================================
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

