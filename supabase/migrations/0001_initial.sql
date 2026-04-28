-- Presence: initial schema, RPCs, RLS, and seed data.
-- See README.md for deploy steps and post-migration cron setup.

-- ─── Extensions ────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS http;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Make sure the function bodies can reach pg_trgm + http unqualified.
-- (`extensions` is where Supabase installs these on the hosted side; locally
-- they may land in public. Including both keeps it portable.)

-- ─── Tables ────────────────────────────────────────────────────────────────
CREATE TABLE schools (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  is_canonical BOOLEAN NOT NULL DEFAULT TRUE,
  is_validated BOOLEAN NOT NULL DEFAULT TRUE,
  signup_count INT NOT NULL DEFAULT 0,
  unlocked_at TIMESTAMPTZ,
  unlock_notified BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX schools_normalized_idx ON schools(normalized_name);
CREATE INDEX schools_normalized_trgm_idx ON schools USING gin (normalized_name gin_trgm_ops);

CREATE TABLE signups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES schools(id),
  phone TEXT UNIQUE NOT NULL,
  country_code TEXT NOT NULL,
  position_in_school INT NOT NULL,
  user_agent TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX signups_school_idx ON signups(school_id);
CREATE INDEX signups_created_idx ON signups(created_at DESC);

CREATE TABLE aggregate_stats (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  total_users INT NOT NULL DEFAULT 0,
  total_schools INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO aggregate_stats (id) VALUES (1);

CREATE TABLE unlock_notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id UUID NOT NULL REFERENCES schools(id),
  reached_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  emailed_to_admin_at TIMESTAMPTZ,
  manual_reviewed_at TIMESTAMPTZ,
  notes TEXT
);
CREATE INDEX unlock_notifications_pending_idx ON unlock_notifications(emailed_to_admin_at)
  WHERE emailed_to_admin_at IS NULL;

-- ─── Seed canonical schools ────────────────────────────────────────────────
INSERT INTO schools (slug, name, normalized_name) VALUES
  ('penn',         'University of Pennsylvania',     'pennsylvania'),
  ('brown',        'Brown University',               'brown'),
  ('tufts',        'Tufts University',               'tufts'),
  ('harvard',      'Harvard University',             'harvard'),
  ('yale',         'Yale University',                'yale'),
  ('columbia',     'Columbia University',            'columbia'),
  ('nyu',          'New York University',            'new york'),
  ('mit',          'MIT',                            'mit'),
  ('stanford',     'Stanford University',            'stanford'),
  ('berkeley',     'UC Berkeley',                    'uc berkeley'),
  ('ucla',         'UCLA',                           'ucla'),
  ('usc',          'USC',                            'usc'),
  ('georgetown',   'Georgetown University',          'georgetown'),
  ('duke',         'Duke University',                'duke'),
  ('northwestern', 'Northwestern University',        'northwestern'),
  ('cornell',      'Cornell University',             'cornell'),
  ('dartmouth',    'Dartmouth College',              'dartmouth'),
  ('princeton',    'Princeton University',           'princeton'),
  ('uchicago',     'University of Chicago',          'chicago'),
  ('umich',        'University of Michigan',         'michigan'),
  ('utexas',       'University of Texas at Austin',  'texas at austin'),
  ('oxford',       'University of Oxford',           'oxford'),
  ('cambridge',    'University of Cambridge',        'cambridge'),
  ('lse',          'LSE',                            'lse'),
  ('ucl',          'University College London',      'london'),
  ('imperial',     'Imperial College London',        'imperial london');

-- ─── Convenience view for at-a-glance signup tracking in Studio ────────────
CREATE OR REPLACE VIEW school_progress AS
SELECT
  s.name,
  s.slug,
  s.signup_count,
  CASE
    WHEN s.unlocked_at IS NOT NULL THEN 'UNLOCKED'
    WHEN s.signup_count >= 30      THEN 'READY'
    WHEN s.signup_count > 0        THEN 'BUILDING'
    ELSE                                'EMPTY'
  END                                   AS status,
  s.unlocked_at,
  s.unlock_notified,
  s.is_canonical,
  s.is_validated,
  s.created_at
FROM schools s
ORDER BY s.signup_count DESC, s.name;

-- ─── normalize_school_name: mirrors the client-side normalization ──────────
CREATE OR REPLACE FUNCTION normalize_school_name(input TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
AS $$
  SELECT trim(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            lower(coalesce(input, '')),
            E'[.,\'"`‘’“”]', '', 'g'
          ),
          '\s+', ' ', 'g'
        ),
        '\y(the|of|university|college|institute|state)\y', '', 'g'
      ),
      '\s+', ' ', 'g'
    )
  );
$$;

-- ─── fuzzy_match_school: returns top 3 by trigram similarity ───────────────
CREATE OR REPLACE FUNCTION fuzzy_match_school(input TEXT)
RETURNS TABLE (id UUID, name TEXT, similarity REAL)
LANGUAGE sql STABLE
AS $$
  WITH q AS (SELECT normalize_school_name(input) AS norm)
  SELECT
    s.id,
    s.name,
    public.similarity(s.normalized_name, q.norm)::REAL
  FROM schools s, q
  WHERE q.norm <> ''
    AND (
      s.normalized_name LIKE '%' || q.norm || '%'
      OR q.norm LIKE '%' || s.normalized_name || '%'
      OR public.similarity(s.normalized_name, q.norm) > 0.4
    )
  ORDER BY public.similarity(s.normalized_name, q.norm) DESC
  LIMIT 3;
$$;

-- ─── register_signup: the one write path the page hits ─────────────────────
CREATE OR REPLACE FUNCTION register_signup(
  p_school_slug       TEXT,
  p_custom_name       TEXT,
  p_custom_normalized TEXT,
  p_phone             TEXT,
  p_country           TEXT,
  p_user_agent        TEXT
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_school_id          UUID;
  v_school_name        TEXT;
  v_normalized_phone   TEXT;
  v_signup_count       INT;
  v_new_position       INT;
  v_match_id           UUID;
  v_match_name         TEXT;
  v_match_sim          REAL;
  v_was_unlocked       TIMESTAMPTZ;
  v_first_signup       BOOL := FALSE;
  v_hipolabs_url       TEXT;
  v_hipolabs_response  RECORD;
  v_hipolabs_body      JSONB;
  v_total_users        INT;
  v_total_schools      INT;
  v_unlocked           BOOL := FALSE;
  v_existing           RECORD;
BEGIN
  -- Normalize phone to E.164: leading '+' followed by digits only.
  v_normalized_phone := '+' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  IF length(v_normalized_phone) < 8 THEN
    RAISE EXCEPTION 'invalid_phone';
  END IF;

  -- Duplicate phone: short-circuit with the school+progress so the page can
  -- render the duplicate-view in one round trip.
  SELECT s.id   AS school_id,
         s.name AS school_name,
         s.signup_count,
         s.unlocked_at IS NOT NULL AS unlocked
    INTO v_existing
    FROM signups sg
    JOIN schools s ON s.id = sg.school_id
   WHERE sg.phone = v_normalized_phone;

  IF FOUND THEN
    SELECT total_users, total_schools
      INTO v_total_users, v_total_schools
      FROM aggregate_stats WHERE id = 1;

    RETURN json_build_object(
      'status',            'duplicate',
      'school_id',         v_existing.school_id,
      'school_name',       v_existing.school_name,
      'school_total',      v_existing.signup_count,
      'school_position',   NULL,
      'aggregate_users',   v_total_users,
      'aggregate_schools', v_total_schools,
      'unlocked',          v_existing.unlocked
    );
  END IF;

  -- Resolve school: known slug, or custom (fuzzy collapse / Hipolabs verify).
  IF p_school_slug IS NOT NULL AND p_school_slug <> '' THEN
    SELECT id, name INTO v_school_id, v_school_name
      FROM schools WHERE slug = p_school_slug;
    IF v_school_id IS NULL THEN
      RAISE EXCEPTION 'unknown_school_slug: %', p_school_slug;
    END IF;
  ELSE
    IF coalesce(p_custom_name, '') = '' THEN
      RAISE EXCEPTION 'missing_school';
    END IF;

    -- Auto-collapse if a strong fuzzy hit exists.
    SELECT id, name, similarity
      INTO v_match_id, v_match_name, v_match_sim
      FROM fuzzy_match_school(p_custom_name)
     WHERE similarity > 0.85
     ORDER BY similarity DESC
     LIMIT 1;

    IF v_match_id IS NOT NULL THEN
      v_school_id   := v_match_id;
      v_school_name := v_match_name;
    ELSE
      -- Otherwise verify against Hipolabs before creating a new entry.
      -- Hipolabs API serves over plain HTTP only (their cert/443 doesn't work).
      v_hipolabs_url :=
        'http://universities.hipolabs.com/search?country=United%20States&name=' ||
        replace(replace(replace(replace(p_custom_name,
          ' ', '%20'), '&', '%26'), '#', '%23'), '?', '%3F');

      v_hipolabs_body := NULL;
      BEGIN
        SELECT * INTO v_hipolabs_response FROM http_get(v_hipolabs_url);
        IF v_hipolabs_response.status = 200 THEN
          v_hipolabs_body := v_hipolabs_response.content::jsonb;
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_hipolabs_body := NULL;
      END;

      IF v_hipolabs_body IS NULL OR jsonb_array_length(v_hipolabs_body) = 0 THEN
        RETURN json_build_object('status', 'school_not_recognized');
      END IF;

      INSERT INTO schools (slug, name, normalized_name, is_canonical, is_validated)
      VALUES (
        'custom-' || substr(md5(p_custom_name || gen_random_uuid()::text), 1, 12),
        p_custom_name,
        coalesce(nullif(p_custom_normalized, ''), normalize_school_name(p_custom_name)),
        FALSE,
        TRUE
      )
      RETURNING id, name INTO v_school_id, v_school_name;
    END IF;
  END IF;

  -- Lock the school row to make position_in_school + count safe under load.
  SELECT signup_count INTO v_signup_count FROM schools WHERE id = v_school_id FOR UPDATE;
  v_first_signup := (v_signup_count = 0);
  v_new_position := v_signup_count + 1;

  BEGIN
    INSERT INTO signups (school_id, phone, country_code, position_in_school, user_agent)
    VALUES (v_school_id, v_normalized_phone, p_country, v_new_position, p_user_agent);
  EXCEPTION WHEN unique_violation THEN
    -- Lost a race on phone uniqueness; treat as duplicate.
    SELECT s.id   AS school_id,
           s.name AS school_name,
           s.signup_count,
           s.unlocked_at IS NOT NULL AS unlocked
      INTO v_existing
      FROM signups sg
      JOIN schools s ON s.id = sg.school_id
     WHERE sg.phone = v_normalized_phone;
    SELECT total_users, total_schools
      INTO v_total_users, v_total_schools
      FROM aggregate_stats WHERE id = 1;
    RETURN json_build_object(
      'status',            'duplicate',
      'school_id',         v_existing.school_id,
      'school_name',       v_existing.school_name,
      'school_total',      v_existing.signup_count,
      'school_position',   NULL,
      'aggregate_users',   v_total_users,
      'aggregate_schools', v_total_schools,
      'unlocked',          v_existing.unlocked
    );
  END;

  UPDATE schools
     SET signup_count = signup_count + 1
   WHERE id = v_school_id
   RETURNING signup_count, unlocked_at INTO v_signup_count, v_was_unlocked;

  IF v_signup_count >= 30 AND v_was_unlocked IS NULL THEN
    UPDATE schools SET unlocked_at = NOW() WHERE id = v_school_id;
    INSERT INTO unlock_notifications (school_id) VALUES (v_school_id);
    v_unlocked := TRUE;
  ELSIF v_was_unlocked IS NOT NULL THEN
    v_unlocked := TRUE;
  END IF;

  UPDATE aggregate_stats
     SET total_users   = total_users + 1,
         total_schools = total_schools + (CASE WHEN v_first_signup THEN 1 ELSE 0 END),
         updated_at    = NOW()
   WHERE id = 1
   RETURNING total_users, total_schools INTO v_total_users, v_total_schools;

  RETURN json_build_object(
    'status',            'ok',
    'school_id',         v_school_id,
    'school_name',       v_school_name,
    'school_total',      v_signup_count,
    'school_position',   v_new_position,
    'aggregate_users',   v_total_users,
    'aggregate_schools', v_total_schools,
    'unlocked',          v_unlocked
  );
END;
$$;

-- ─── get_progress: read-only fetch for the duplicate view's init ───────────
CREATE OR REPLACE FUNCTION get_progress(p_school_id UUID)
RETURNS json
LANGUAGE sql STABLE
SET search_path = public
AS $$
  SELECT json_build_object(
    'school_id',         s.id,
    'school_name',       s.name,
    'school_total',      s.signup_count,
    'aggregate_users',   a.total_users,
    'aggregate_schools', a.total_schools,
    'unlocked',          s.unlocked_at IS NOT NULL
  )
  FROM schools s, aggregate_stats a
  WHERE s.id = p_school_id AND a.id = 1;
$$;

-- ─── RLS: lock down everything, expose only what the page needs ────────────
ALTER TABLE schools              ENABLE ROW LEVEL SECURITY;
ALTER TABLE signups              ENABLE ROW LEVEL SECURITY;
ALTER TABLE aggregate_stats      ENABLE ROW LEVEL SECURITY;
ALTER TABLE unlock_notifications ENABLE ROW LEVEL SECURITY;

CREATE POLICY "schools are publicly readable"
  ON schools FOR SELECT TO anon, authenticated
  USING (TRUE);

CREATE POLICY "aggregate_stats are publicly readable"
  ON aggregate_stats FOR SELECT TO anon, authenticated
  USING (TRUE);

-- signups + unlock_notifications: no policies, no anon access.
-- Writes happen through SECURITY DEFINER RPCs only.

REVOKE ALL ON FUNCTION register_signup(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION register_signup(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

REVOKE ALL ON FUNCTION get_progress(UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION get_progress(UUID) TO anon, authenticated;

GRANT SELECT ON school_progress TO anon, authenticated;
