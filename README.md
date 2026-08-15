# Range Ledger

A shooting academy management app (student/coach/admin dashboards, fee
tracking with real PDF invoices, attendance approval flow, match calendar,
performance logging) backed by Supabase (Postgres + Auth + Storage).

## What's in here

```
index.html                                 the whole app (single file)
supabase/
  config.toml                              Supabase project config (safe to commit)
  seed.sql                                 optional sample data for preview branches
  migrations/
    20260101000000_initial_schema.sql      the database schema (tables + RLS policies)
```

## First-time setup (you've likely already done most of this)

1. Create a Supabase project at [supabase.com](https://supabase.com).
2. In `index.html`, set `SUPABASE_URL` and `SUPABASE_ANON_KEY` near the top
   of the `<script>` block to your project's values (Project Settings > API).
3. In `supabase/config.toml`, replace `YOUR_PROJECT_ID` with your project ID
   (found in your dashboard URL: `supabase.com/dashboard/project/<project-id>`).

## Connecting GitHub (so schema changes deploy automatically)

Once this folder is pushed to a GitHub repo:

1. In the Supabase dashboard, go to **Project Settings → Integrations**.
2. Under **GitHub Integration**, click **Authorize GitHub** and approve access.
3. Choose this repository, and set the **working directory** to `.`
   (since `supabase/` sits at the repo root).
4. Turn on **Deploy to production** so pushes/merges to your main branch
   automatically apply new files in `supabase/migrations/` to your live
   database — no more manually pasting SQL into the SQL Editor.
5. (Optional) In your GitHub repo's branch protection settings, enable
   **"Require status checks to pass before merging"** and select the
   Supabase check, so a broken migration can't be merged by accident.

## Making a schema change later

Add a new file to `supabase/migrations/`, named with a timestamp prefix so
it sorts after the existing ones, e.g.:

```
supabase/migrations/20260215093000_add_coach_bio_field.sql
```

Put only the *new* SQL in it (e.g. `alter table coaches add column bio text;`)
— migrations are additive and applied in order, so don't repeat what's
already in the initial migration. Commit, push, and (if you've enabled
"Deploy to production") it applies automatically.

## Local development (optional)

If you install the [Supabase CLI](https://supabase.com/docs/guides/local-development),
running `supabase link` inside this folder will regenerate `config.toml`
with everything filled in correctly for your project, and `supabase db push`
lets you apply migrations from your machine instead of only via GitHub.
