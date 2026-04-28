-- 0005_return_position_on_dup.sql
-- When the backend detects a duplicate (by phone or device_id), also return
-- the user's existing position_in_school. The duplicate-view's "this is you"
-- pulsating dot needs that position; previously it was returned as NULL and
-- the dot grid lost the pulse on revisit.

CREATE OR REPLACE FUNCTION register_signup(
  p_school_slug       TEXT,
  p_custom_name       TEXT,
  p_custom_normalized TEXT,
  p_phone             TEXT,
  p_country           TEXT,
  p_user_agent        TEXT,
  p_device_id         TEXT DEFAULT NULL,
  p_referrer          TEXT DEFAULT NULL
) RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_school_id          UUID;
  v_school_slug        TEXT;
  v_school_name        TEXT;
  v_normalized_phone   TEXT;
  v_normalized_input   TEXT;
  v_signup_count       INT;
  v_new_position       INT;
  v_match_id           UUID;
  v_match_name         TEXT;
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
  v_clean_device       TEXT;
  v_referrer_school_id UUID;
BEGIN
  v_normalized_phone := '+' || regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  IF length(v_normalized_phone) < 8 THEN
    RAISE EXCEPTION 'invalid_phone';
  END IF;

  v_clean_device := nullif(trim(coalesce(p_device_id, '')), '');

  SELECT s.id   AS school_id,
         s.slug AS school_slug,
         s.name AS school_name,
         s.signup_count,
         s.unlocked_at IS NOT NULL AS unlocked,
         sg.position_in_school AS my_position
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
      'school_slug',       v_existing.school_slug,
      'school_name',       v_existing.school_name,
      'school_total',      v_existing.signup_count,
      'school_position',   v_existing.my_position,
      'aggregate_users',   v_total_users,
      'aggregate_schools', v_total_schools,
      'unlocked',          v_existing.unlocked
    );
  END IF;

  IF v_clean_device IS NOT NULL THEN
    SELECT s.id   AS school_id,
           s.slug AS school_slug,
           s.name AS school_name,
           s.signup_count,
           s.unlocked_at IS NOT NULL AS unlocked,
           sg.position_in_school AS my_position
      INTO v_existing
      FROM signups sg
      JOIN schools s ON s.id = sg.school_id
     WHERE sg.device_id = v_clean_device;

    IF FOUND THEN
      SELECT total_users, total_schools
        INTO v_total_users, v_total_schools
        FROM aggregate_stats WHERE id = 1;
      RETURN json_build_object(
        'status',            'duplicate',
        'school_id',         v_existing.school_id,
        'school_slug',       v_existing.school_slug,
        'school_name',       v_existing.school_name,
        'school_total',      v_existing.signup_count,
        'school_position',   v_existing.my_position,
        'aggregate_users',   v_total_users,
        'aggregate_schools', v_total_schools,
        'unlocked',          v_existing.unlocked
      );
    END IF;
  END IF;

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

    IF length(trim(p_custom_name)) < 2 OR length(v_normalized_input) = 0 THEN
      RETURN json_build_object('status', 'school_not_recognized');
    END IF;

    SELECT s.id, s.name
      INTO v_school_id, v_school_name
      FROM school_aliases a
      JOIN schools s ON s.id = a.school_id
     WHERE a.alias_normalized = v_normalized_input
     LIMIT 1;

    IF v_school_id IS NULL THEN
      SELECT s.id, s.name
        INTO v_match_id, v_match_name
        FROM schools s
       WHERE v_normalized_input <> ''
         AND (
           public.similarity(s.normalized_name, v_normalized_input) > 0.85
           OR (
             length(v_normalized_input) >= 8
             AND length(s.normalized_name) >= 8
             AND (
               s.normalized_name LIKE '%' || v_normalized_input || '%'
               OR v_normalized_input LIKE '%' || s.normalized_name || '%'
             )
             AND public.similarity(s.normalized_name, v_normalized_input) > 0.55
           )
         )
       ORDER BY public.similarity(s.normalized_name, v_normalized_input) DESC
       LIMIT 1;

      IF v_match_id IS NOT NULL THEN
        v_school_id   := v_match_id;
        v_school_name := v_match_name;
      END IF;
    END IF;

    IF v_school_id IS NULL THEN
      v_validated := FALSE;

      BEGIN
        PERFORM http_set_curlopt('CURLOPT_TIMEOUT_MS', '3000');
      EXCEPTION WHEN OTHERS THEN
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

  IF coalesce(p_referrer, '') <> '' THEN
    SELECT id INTO v_referrer_school_id FROM schools WHERE slug = p_referrer;
  END IF;

  SELECT slug INTO v_school_slug FROM schools WHERE id = v_school_id;

  SELECT signup_count INTO v_signup_count FROM schools WHERE id = v_school_id FOR UPDATE;
  v_first_signup := (v_signup_count = 0);
  v_new_position := v_signup_count + 1;

  BEGIN
    INSERT INTO signups (school_id, phone, country_code, position_in_school, user_agent, device_id, referrer_school_id)
    VALUES (v_school_id, v_normalized_phone, p_country, v_new_position, p_user_agent, v_clean_device, v_referrer_school_id);
  EXCEPTION WHEN unique_violation THEN
    SELECT s.id   AS school_id,
           s.slug AS school_slug,
           s.name AS school_name,
           s.signup_count,
           s.unlocked_at IS NOT NULL AS unlocked,
           sg.position_in_school AS my_position
      INTO v_existing
      FROM signups sg
      JOIN schools s ON s.id = sg.school_id
     WHERE sg.phone = v_normalized_phone
        OR (v_clean_device IS NOT NULL AND sg.device_id = v_clean_device)
     LIMIT 1;
    SELECT total_users, total_schools
      INTO v_total_users, v_total_schools
      FROM aggregate_stats WHERE id = 1;
    RETURN json_build_object(
      'status',            'duplicate',
      'school_id',         v_existing.school_id,
      'school_slug',       v_existing.school_slug,
      'school_name',       v_existing.school_name,
      'school_total',      v_existing.signup_count,
      'school_position',   v_existing.my_position,
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
    'school_slug',       v_school_slug,
    'school_name',       v_school_name,
    'school_total',      v_signup_count,
    'school_position',   v_new_position,
    'aggregate_users',   v_total_users,
    'aggregate_schools', v_total_schools,
    'unlocked',          v_unlocked
  );
END;
$$;
