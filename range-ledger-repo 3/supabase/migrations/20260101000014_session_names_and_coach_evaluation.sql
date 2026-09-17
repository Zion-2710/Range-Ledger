-- =============================================================================
-- Two additions to support a richer, shareable progress report:
--  1. An optional descriptive name per logged session (e.g. "Academy
--     Monthly Match #8") alongside the existing auto-generated M1/M2 label.
--  2. A free-text coach evaluation on each student, shown on their
--     progress report when the coach has written one.
-- =============================================================================

alter table match_scores add column if not exists session_name text;
alter table students add column if not exists coach_evaluation text;
