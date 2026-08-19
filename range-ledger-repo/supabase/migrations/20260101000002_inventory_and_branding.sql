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
