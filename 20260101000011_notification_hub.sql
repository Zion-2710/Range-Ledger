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
