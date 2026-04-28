# Presence — landing page + Supabase backend

Single-file static landing page (`index.html`) backed by Supabase Postgres,
two RPCs (`register_signup`, `get_progress`), and one Edge Function
(`notify-unlock`) that emails the admin whenever a school crosses 30 signups.

---

## 1. Create the Supabase project

1. Go to <https://supabase.com>, sign in, and click **New Project**.
2. Pick the free tier, choose a region close to your users, and let it provision.
3. Once it's ready, open **Project Settings → API**. You'll need:
   - **Project URL** → goes into `SUPABASE_URL`
   - **`anon` public key** → goes into `SUPABASE_ANON_KEY`
   - **`service_role` secret key** → only used by the Edge Function (never the browser)

Keep the project ref handy too — it's the subdomain in your project URL
(e.g. `https://abcdxyz.supabase.co` → ref is `abcdxyz`).

## 2. Link and push the migration

```bash
# one-time link
supabase login
supabase link --project-ref <your-project-ref>

# push the schema, RPCs, RLS policies, and seed data
supabase db push
```

Verify in Supabase Studio:
- **Database → Tables**: `schools` (26 seeded rows), `signups`, `aggregate_stats`, `unlock_notifications`
- **Database → Functions**: `register_signup`, `get_progress`, `fuzzy_match_school`, `normalize_school_name`
- **Database → Views**: `school_progress`

## 3. Deploy the Edge Function

```bash
supabase functions deploy notify-unlock
```

Then set the secrets it reads:

```bash
supabase secrets set ADMIN_EMAIL=you@example.com
supabase secrets set RESEND_API_KEY=re_xxxxxxxxxxxx
# Optional — defaults to onboarding@resend.dev which works in Resend's sandbox.
# To send from your own domain, verify it in Resend first.
supabase secrets set RESEND_FROM_EMAIL='Presence <hello@yourdomain.com>'
```

`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected automatically by
the Supabase Functions runtime — you don't set them yourself.

Get a Resend API key at <https://resend.com> (free tier: 100/day, 3000/month).

## 4. Schedule the cron

Run this once in **Database → SQL Editor**, replacing the placeholders:

```sql
SELECT cron.schedule(
  'notify-unlock-every-5min',
  '*/5 * * * *',
  $$
  SELECT net.http_post(
    url     := 'https://<your-project-ref>.supabase.co/functions/v1/notify-unlock',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer <your-service-role-key>'
    )
  );
  $$
);
```

Confirm with `SELECT * FROM cron.job;`. To stop it: `SELECT cron.unschedule('notify-unlock-every-5min');`.

## 5. Wire the frontend

Open `index.html`, find the `PRESENCE_CONFIG` block near the bottom, and
fill in the URL and anon key:

```html
<script>
window.PRESENCE_CONFIG = {
  SUPABASE_URL: 'https://<your-project-ref>.supabase.co',
  SUPABASE_ANON_KEY: '<your-anon-key>'
};
</script>
```

**Never paste the `service_role` key here.** The anon key is safe in client
code; the service role bypasses RLS and must stay server-side.

## 6. Deploy the static site

The page is a single file with no build step. Drop it on any static host:

The file is named `index.html`, so every static host serves it at `/` by default.

**Vercel.** From the project directory:
```bash
npx vercel
```

**Netlify.**
```bash
npx netlify deploy --prod --dir .
```

**Cloudflare Pages, GitHub Pages, S3, etc.** — same idea. It's just one HTML file.

---

## Where to watch signups

You don't need an admin UI. Open Supabase Studio and:

- **Table Editor → `schools`** — sort by `signup_count` desc to see which
  schools are gaining traction. `unlocked_at` is set the moment a school
  hits 30. `unlock_notified` tracks whether you've manually reviewed it.
- **Database → Views → `school_progress`** — same thing pre-sorted with a
  human-readable `status` column (`UNLOCKED` / `READY` / `BUILDING` / `EMPTY`).
- **Table Editor → `signups`** — every individual signup with phone, country,
  position, user-agent, timestamp. Filter by `school_id` to see one school's roster.
- **Table Editor → `unlock_notifications`** — pending unlocks awaiting your
  manual review. The `notify-unlock` cron emails you when new rows show up.

When you receive an unlock email, the manual review flow is:
1. Open the email — it lists school name, count, every phone with timestamp.
2. Verify the signups look real:
   - Spread out over time, not a 60-second burst
   - Different phone-number patterns
   - User-agents not all identical (check the `signups` table)
3. If they pass, manually text the list. Then update
   `schools.unlock_notified = true` and `unlock_notifications.manual_reviewed_at = now()`.

---

## Local development & smoke tests

```bash
# Start a local Supabase stack (Postgres + Studio + Edge Functions runtime)
supabase start

# Apply the migration to the local DB
supabase db reset
```

Studio runs at <http://localhost:54323>. The local DB credentials print to
stdout when `supabase start` finishes.

Run the smoke tests against local:

```bash
# Open the SQL editor in local Studio, or:
supabase db execute --file scripts/smoke.sql
```

(See `scripts/smoke.sql` if added — otherwise paste the queries from the
"smoke test" section below into Studio's SQL editor.)

### Smoke test SQL

```sql
-- 1. Canonical school signup
SELECT register_signup('brown', NULL, NULL, '+1 555 010 0001', '+1', 'smoke-test');
-- Expect: status=ok, school_position=1, school_total=1, aggregate_users=1, aggregate_schools=1.

-- 2. Duplicate phone
SELECT register_signup('brown', NULL, NULL, '+1 555 010 0001', '+1', 'smoke-test');
-- Expect: status=duplicate, same school_id, school_total=1.

-- 3. Custom school validated via Hipolabs
SELECT register_signup(NULL, 'Vanderbilt University', 'vanderbilt', '+1 555 010 0002', '+1', 'smoke-test');
-- Expect: status=ok, new schools row with is_canonical=false, is_validated=true.

-- 4. Custom school rejected
SELECT register_signup(NULL, 'asdfqwerty', 'asdfqwerty', '+1 555 010 0003', '+1', 'smoke-test');
-- Expect: status=school_not_recognized.

-- 5. Counter check
SELECT * FROM school_progress LIMIT 5;
SELECT * FROM aggregate_stats;
```

### Reset local data

```bash
supabase db reset   # drops + re-runs migrations
```

---

## File map

```
index.html                       — the single-page landing site
package.json                       — declares @supabase/supabase-js (CDN load is what runs in browser)
.env.local                         — placeholder env vars (NOT committed; see .gitignore)
supabase/
  config.toml                      — `supabase init` output
  migrations/0001_initial.sql      — schema, RPCs, RLS, seed
  functions/notify-unlock/
    index.ts                       — admin-email worker, runs every 5 min via pg_cron
README.md                          — this file
```

## What's deliberately not done yet

- No SMS sending — when a school unlocks, you text the list manually after reviewing.
- No CAPTCHA — add hCaptcha if abuse appears.
- No admin UI — Supabase Studio is the admin UI.
- No design changes — the visual surface of `index.html` is unchanged.
