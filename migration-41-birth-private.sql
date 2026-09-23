-- ────────────────────────────────────────────────────────────────────
-- 41. 생년월일도 profiles 밖으로
--
--   profiles_read 정책은 같은 루틴에 있는 사람에게 행 전체를 열어 준다.
--   이름은 그래야 서로를 부를 수 있지만 생년월일은 아니다.
--   지금은 같은 루틴 아이가 남의 생일을 API 로 읽을 수 있다.
--
--   38 에서 만든 profiles_private 로 옮긴다. 본인과 운영진만 본다.
--   나이를 보는 쪽은 check_participant_insert() 하나뿐이고,
--   그건 SECURITY DEFINER 라 RLS 를 지나서 읽는다.
--
--   ⚠️ 38 번을 먼저 돌려야 한다 (profiles_private 이 있어야 한다).
-- ────────────────────────────────────────────────────────────────────

-- ── 1. 자리를 먼저 만들고 값을 옮긴다 ──────────────────
ALTER TABLE profiles_private ADD COLUMN IF NOT EXISTS birth_date date;
COMMENT ON COLUMN profiles_private.birth_date IS '만 14세 확인용. 본인과 운영진만 본다';

INSERT INTO profiles_private (id, birth_date)
SELECT id, birth_date FROM profiles WHERE birth_date IS NOT NULL
ON CONFLICT (id) DO UPDATE SET birth_date = EXCLUDED.birth_date;

-- ── 2. 나이를 보는 곳을 새 자리로 ──────────────────────
-- plpgsql 은 만들 때 컬럼을 확인하지 않는다. 컬럼을 지우기 전에 먼저 바꿔 둔다
CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text; v_age int; v_verify text;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  SELECT age_years(pp.birth_date) INTO v_age
    FROM profiles_private pp WHERE pp.id = NEW.user_id;
  SELECT p.verify_status INTO v_verify
    FROM profiles p WHERE p.id = NEW.user_id;

  -- 생년월일이 없는 사람(예전 가입자)은 나이로 막지 않는다
  IF v_age IS NOT NULL AND v_age < 14 THEN
    RAISE EXCEPTION '한끗독서는 만 14세부터 함께할 수 있어요';
  END IF;

  IF COALESCE(v_verify, 'none') <> 'approved' THEN
    RAISE EXCEPTION '청소년 확인이 끝나야 루틴에 참여할 수 있어요';
  END IF;

  NEW.status := 'approved';

  IF COALESCE(NEW.book_photo_url, '') = '' THEN
    RAISE EXCEPTION '읽을 책 사진을 올려주세요';
  END IF;
  IF COALESCE(btrim(NEW.book_title), '') = '' THEN
    RAISE EXCEPTION '읽을 책 제목을 적어주세요';
  END IF;
  IF COALESCE(btrim(NEW.note), '') = '' THEN
    RAISE EXCEPTION '참여 각오를 적어주세요';
  END IF;

  SELECT max_people, status INTO v_max, v_status FROM routines WHERE id = NEW.routine_id;
  IF v_status = 'done' THEN
    RAISE EXCEPTION '이미 끝난 루틴이에요';
  END IF;
  SELECT count(*) INTO v_now FROM routine_participants
   WHERE routine_id = NEW.routine_id AND status = 'approved';
  IF v_max IS NOT NULL AND v_now >= v_max THEN
    RAISE EXCEPTION '정원이 찼어요';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 3. 한 번 적으면 못 바꾼다 ──────────────────────────
-- 나이를 바꿔가며 우회하는 길을 닫는다. profiles 에 있을 때 하던 일을 옮겨 온다
CREATE OR REPLACE FUNCTION check_private_write() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  NEW.id := OLD.id;
  IF OLD.birth_date IS NOT NULL THEN NEW.birth_date := OLD.birth_date; END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS private_write_guard ON profiles_private;
CREATE TRIGGER private_write_guard BEFORE UPDATE ON profiles_private
  FOR EACH ROW EXECUTE FUNCTION check_private_write();

-- ── 4. profiles 쪽 잠금에서 뺀다 ───────────────────────
CREATE OR REPLACE FUNCTION check_profile_write() RETURNS trigger AS $$
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' THEN
    NEW.id         := OLD.id;
    NEW.role       := OLD.role;
    NEW.can_lead   := OLD.can_lead;
    NEW.created_at := OLD.created_at;
    NEW.verified_at := OLD.verified_at;
    NEW.verify_kind := OLD.verify_kind;
    IF OLD.policy_agreed_at IS NOT NULL THEN NEW.policy_agreed_at := OLD.policy_agreed_at; END IF;
    IF NEW.verify_status <> OLD.verify_status THEN
      IF OLD.verify_status IN ('none', 'rejected') AND NEW.verify_status = 'pending' THEN
        NEW.verify_reason := NULL;
      ELSE
        NEW.verify_status := OLD.verify_status;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 5. 가입할 때도 새 자리로 ───────────────────────────
CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger AS $$
DECLARE m jsonb := NEW.raw_user_meta_data;
BEGIN
  BEGIN
    INSERT INTO profiles (id, name, nick, role, region,
                          school_status, marketing_ok, policy_agreed_at)
    VALUES (NEW.id,
            COALESCE(NULLIF(btrim(m->>'name'), ''), '이름없음'),
            NULLIF(btrim(m->>'nick'), ''),
            'youth',
            m->>'region',
            NULLIF(btrim(m->>'school_status'), ''),
            COALESCE((m->>'marketing_ok')::boolean, false),
            COALESCE(NULLIF(m->>'policy_agreed_at', '')::timestamptz, now()))
    ON CONFLICT (id) DO NOTHING;

    -- 번호와 생년월일은 남에게 보이면 안 되는 것들이라 따로 둔다
    INSERT INTO profiles_private (id, phone, birth_date)
    VALUES (NEW.id,
            NULLIF(btrim(m->>'phone'), ''),
            NULLIF(m->>'birth_date', '')::date)
    ON CONFLICT (id) DO UPDATE
       SET phone      = COALESCE(EXCLUDED.phone, profiles_private.phone),
           birth_date = COALESCE(EXCLUDED.birth_date, profiles_private.birth_date);
  EXCEPTION WHEN OTHERS THEN
    -- 여기서 막으면 가입 자체가 통째로 막힌다 (한끗루틴에서 겪었다)
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 6. age_years 는 STABLE 이 맞다 ─────────────────────
-- now() 를 쓰면서 IMMUTABLE 이라고 적혀 있었다. 뜻은 「입력이 같으면 답도 같다」인데
-- 오늘이 지나면 답이 달라진다. 지금은 탈이 없지만 계획기가 값을 굳혀 버릴 수 있다
CREATE OR REPLACE FUNCTION age_years(p_birth date) RETURNS int AS $$
  SELECT CASE WHEN p_birth IS NULL THEN NULL
         ELSE EXTRACT(year FROM age((now() AT TIME ZONE 'Asia/Seoul')::date, p_birth))::int END;
$$ LANGUAGE sql STABLE;

-- ── 7. 이제 지운다 ─────────────────────────────────────
ALTER TABLE profiles DROP COLUMN IF EXISTS birth_date;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT u.email,
       p.name AS 이름, p.nick AS 닉네임,
       pp.birth_date AS 생년월일, age_years(pp.birth_date) AS 만나이,
       (pp.phone IS NOT NULL) AS 번호있음,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'profiles' AND column_name = 'birth_date') AS profiles에남은생일
  FROM profiles p
  JOIN auth.users u ON u.id = p.id
  LEFT JOIN profiles_private pp ON pp.id = p.id
 ORDER BY u.email;
