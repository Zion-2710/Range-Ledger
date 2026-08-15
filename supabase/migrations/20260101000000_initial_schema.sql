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
