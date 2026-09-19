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
