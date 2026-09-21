-- Lets an account turn on "email code" sign-in verification as an
-- alternative to the authenticator-app (TOTP) 2FA already in place — a
-- second option, not a replacement. Actual code delivery uses Supabase's
-- own built-in auth mailer (signInWithOtp / verifyOtp with type: 'email'),
-- not a custom Edge Function, so it works without a custom domain.
alter table public.profiles add column if not exists email_2fa_enabled boolean not null default false;
