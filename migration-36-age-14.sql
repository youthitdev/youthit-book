-- 한끗독서 마이그레이션 36
-- 생년월일을 받고, 만 14세 미만은 이용할 수 없게 한다
--
-- 왜:
--   만 14세 미만은 법정대리인(보호자) 동의가 있어야 개인정보를 받을 수 있다.
--   보호자 동의를 받는 절차를 만드는 것보다, 14세부터 쓰게 하는 편이 맞다고
--   보았다. 동의서를 받아두고 관리하는 것 자체가 부담이고 위험이다.
--
-- 어디서 막나:
--   가입 자체는 막지 않는다. handle_new_user() 는 실패해도 가입을 막지 않도록
--   일부러 그렇게 만들어져 있다 (한끗루틴에서 이 트리거가 500 을 내 가입이
--   통째로 막힌 적이 있다). 그래서 「루틴 참여」에서 막는다 — 모든 활동의 입구다.
--
-- 이미 가입한 사람:
--   생년월일이 없다. 막지 않는다. 새로 가입하는 사람부터 화면에서 받는다.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS birth_date date;
COMMENT ON COLUMN profiles.birth_date IS '만 14세 확인용. 14세 미만은 참여할 수 없다';

-- 본인이 고칠 수 없게. 나이를 바꿔가며 우회하는 길을 닫는다
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
    -- 한 번 적으면 못 바꾼다. 비어 있을 때만 채울 수 있다
    IF OLD.birth_date IS NOT NULL THEN NEW.birth_date := OLD.birth_date; END IF;
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

-- 가입할 때 넘긴 생년월일을 프로필에 옮긴다
CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger AS $$
BEGIN
  BEGIN
    INSERT INTO profiles (id, name, role, region, birth_date)
    VALUES (NEW.id,
            COALESCE(NEW.raw_user_meta_data->>'name', '이름없음'),
            'youth',
            NEW.raw_user_meta_data->>'region',
            NULLIF(NEW.raw_user_meta_data->>'birth_date', '')::date)
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    -- 여기서 막으면 가입 자체가 통째로 막힌다 (한끗루틴에서 겪었다)
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 만 나이
CREATE OR REPLACE FUNCTION age_years(p_birth date) RETURNS int AS $$
  SELECT CASE WHEN p_birth IS NULL THEN NULL
         ELSE EXTRACT(year FROM age((now() AT TIME ZONE 'Asia/Seoul')::date, p_birth))::int END;
$$ LANGUAGE sql IMMUTABLE;

-- 참여에서 막는다. 모든 활동의 입구다
CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text; v_age int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  SELECT age_years(birth_date) INTO v_age FROM profiles WHERE id = NEW.user_id;
  -- 생년월일이 없는 사람(예전 가입자)은 막지 않는다
  IF v_age IS NOT NULL AND v_age < 14 THEN
    RAISE EXCEPTION '한끗독서는 만 14세부터 함께할 수 있어요';
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
    RAISE EXCEPTION '이미 끝난 루틴입니다';
  END IF;

  SELECT count(*) INTO v_now FROM routine_participants
   WHERE routine_id = NEW.routine_id AND status = 'approved';
  IF v_now >= COALESCE(v_max, 0) THEN
    RAISE EXCEPTION '모집 인원이 찼습니다';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';

-- ↓ 사람별 나이. 줄이 나와야 성공이다
SELECT u.email, p.name AS 이름, p.birth_date AS 생년월일,
       age_years(p.birth_date) AS 만나이
  FROM profiles p JOIN auth.users u ON u.id = p.id ORDER BY p.name;
