-- =============================================================================
-- Data integrity constraints + storage hardening.
--
-- RLS controls WHO can write to a table, but says nothing about WHAT
-- values are valid — someone could bypass this app's UI entirely and call
-- the Supabase REST API directly with a negative price, an absurd GST
-- percentage, or a zero-quantity item request. These CHECK constraints
-- make invalid data impossible to insert regardless of how the request
-- was made, not just inconvenient to enter through the app's own forms.
--
-- Existing rows are left alone even if they'd violate a new constraint
-- (Postgres only enforces CHECK on new/updated rows going forward) — if
-- any of the "not valid" additions below report a violation, that's
-- telling you real bad data already exists and is worth a manual look.
-- =============================================================================

alter table inventory_items add constraint inventory_items_quantity_nonneg check (quantity >= 0) not valid;
alter table inventory_items add constraint inventory_items_price_nonneg check (unit_price >= 0) not valid;

alter table inventory_issues add constraint inventory_issues_quantity_positive check (quantity > 0) not valid;
alter table inventory_issues add constraint inventory_issues_unit_price_nonneg check (unit_price >= 0) not valid;

alter table qualification_standards add constraint qualification_standards_cutoff_positive check (cutoff_score > 0) not valid;
alter table qualification_standards add constraint qualification_standards_shots_positive check (shots > 0) not valid;

alter table coaches add constraint coaches_gst_percent_range check (gst_percent >= 0 and gst_percent <= 100) not valid;

alter table invoices add constraint invoices_amount_nonneg check (amount >= 0) not valid;
alter table invoices add constraint invoices_gst_percent_range check (gst_percent >= 0 and gst_percent <= 100) not valid;
alter table invoices add constraint invoices_gst_amount_nonneg check (gst_amount >= 0) not valid;

alter table match_scores add constraint match_scores_score_nonneg check (score >= 0) not valid;

alter table notification_broadcasts add constraint notification_broadcasts_recipient_count_nonneg check (recipient_count >= 0) not valid;

-- Validate each constraint now, so you actually see it in the SQL editor
-- output if any existing row already violates one — rather than the
-- constraint just silently applying to future writes only.
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
-- Avatars storage: server-side size and type limits, so the 1MB compression
-- in the app's own JS isn't the only thing standing between a user and
-- uploading a 200MB file or an .exe renamed to .jpg — this is enforced by
-- Supabase Storage itself regardless of what a client sends.
-- =============================================================================
update storage.buckets
set file_size_limit = 2097152, -- 2MB raw ceiling (the app compresses to ~1MB client-side; this is a hard server-side backstop, not the target size)
    allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
where id = 'avatars';
