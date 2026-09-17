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
