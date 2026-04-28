-- 0002_global_schools.sql
-- Open the system up to any high school or college worldwide.
--   • Hipolabs is no longer a gate — it's enrichment that flips is_validated.
--   • The country=United States filter is dropped (worldwide universities).
--   • A school_aliases table maps acronyms / nicknames → canonical school_id,
--     since trigram similarity can't bridge "TRINS" → "Trivandrum International School".
--   • Custom schools are accepted as long as the input has at least 2 chars
--     after normalization. The 30-signup unlock + manual admin review remains
--     the abuse gate.

-- ─── school_aliases ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS school_aliases (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  school_id        UUID NOT NULL REFERENCES schools(id) ON DELETE CASCADE,
  alias            TEXT NOT NULL,
  alias_normalized TEXT NOT NULL UNIQUE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS school_aliases_school_id_idx ON school_aliases(school_id);

ALTER TABLE school_aliases ENABLE ROW LEVEL SECURITY;
-- No public policies — read/write happens only through the SECURITY DEFINER
-- RPC and the service_role key (which bypasses RLS).

-- ─── Seed: acronyms / nicknames that fuzzy matching can't bridge ──────────
-- Skipped ambiguous tokens like "Michigan" (Michigan State conflict) and
-- "UT" (Tennessee/Texas/Toronto). Admin can add more in Studio later.
INSERT INTO school_aliases (school_id, alias, alias_normalized)
SELECT s.id, v.alias, public.normalize_school_name(v.alias)
FROM (VALUES
  ('penn',     'UPenn'),
  ('penn',     'Penn'),
  ('berkeley', 'Cal'),
  ('berkeley', 'UCB'),
  ('umich',    'UMich'),
  ('umich',    'UofM'),
  ('utexas',   'UT Austin'),
  ('uchicago', 'UChicago'),
  ('mit',      'Massachusetts Institute of Technology'),
  ('usc',      'University of Southern California'),
  ('ucla',     'University of California Los Angeles'),
  ('ucla',     'University of California, Los Angeles'),
  ('lse',      'London School of Economics'),
  ('nyu',      'NYU')
) AS v(slug, alias)
JOIN schools s ON s.slug = v.slug
ON CONFLICT (alias_normalized) DO NOTHING;

-- ─── register_signup: global-friendly rewrite ─────────────────────────────
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
  v_normalized_input   TEXT;
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
  v_validated          BOOL := FALSE;
  v_total_users        INT;
  v_total_schools      INT;
  v_unlocked           BOOL := FALSE;
  v_existing           RECORD;
BEGIN
  v_normalized_phone := '+' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  IF length(v_normalized_phone) < 8 THEN
    RAISE EXCEPTION 'invalid_phone';
  END IF;

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

  -- Resolve school: known slug, or custom (alias / fuzzy / accept-with-enrichment).
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

    v_normalized_input := coalesce(nullif(p_custom_normalized, ''),
                                   normalize_school_name(p_custom_name));

    -- Reject only if the input is essentially empty after normalization.
    IF length(trim(p_custom_name)) < 2 OR length(v_normalized_input) = 0 THEN
      RETURN json_build_object('status', 'school_not_recognized');
    END IF;

    -- 1. Exact alias hit (acronyms / nicknames seeded in school_aliases).
    SELECT s.id, s.name
      INTO v_school_id, v_school_name
      FROM school_aliases a
      JOIN schools s ON s.id = a.school_id
     WHERE a.alias_normalized = v_normalized_input
     LIMIT 1;

    -- 2. Fuzzy collapse against existing schools (>0.85 similarity).
    IF v_school_id IS NULL THEN
      SELECT id, name, similarity
        INTO v_match_id, v_match_name, v_match_sim
        FROM fuzzy_match_school(p_custom_name)
       WHERE similarity > 0.85
       ORDER BY similarity DESC
       LIMIT 1;

      IF v_match_id IS NOT NULL THEN
        v_school_id   := v_match_id;
        v_school_name := v_match_name;
      END IF;
    END IF;

    -- 3. Create new school. Hipolabs is enrichment, not a gate.
    IF v_school_id IS NULL THEN
      v_validated := FALSE;

      -- Cap Hipolabs at 3s so a slow university API doesn't slow signups.
      BEGIN
        PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '3000');
      EXCEPTION WHEN OTHERS THEN
        -- http_set_curlopt may not be available; fine, fall through.
        NULL;
      END;

      v_hipolabs_url :=
        'http://universities.hipolabs.com/search?name=' ||
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

      IF v_hipolabs_body IS NOT NULL AND jsonb_array_length(v_hipolabs_body) > 0 THEN
        v_validated := TRUE;
      END IF;

      INSERT INTO schools (slug, name, normalized_name, is_canonical, is_validated)
      VALUES (
        'custom-' || substr(md5(p_custom_name || gen_random_uuid()::text), 1, 12),
        p_custom_name,
        v_normalized_input,
        FALSE,
        v_validated
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
