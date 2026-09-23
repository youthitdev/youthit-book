-- ────────────────────────────────────────────────────────────────────
-- 38. 가입 항목을 한끗루틴과 맞춘다
--
--   닉네임 · 실명 · 생년월일 · 이메일 · 비밀번호 · 휴대폰 · 지역 · 재학상태
--   + 개인정보 동의(필수) · 마케팅 수신(선택)
--
-- 휴대폰은 profiles 에 두지 않는다.
--   profiles_read 정책은 「같은 루틴에 있는 사람」에게 행 전체를 열어 준다.
--   이름까지는 그래야 서로를 부를 수 있지만, 번호까지 열리면 같은 루틴
--   아이가 남의 번호를 긁어 갈 수 있다. 본인과 운영진만 보는 표로 뺀다.
-- ────────────────────────────────────────────────────────────────────

-- ── 1. profiles 에 붙는 칸 ─────────────────────────────
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS nick             text,
  ADD COLUMN IF NOT EXISTS school_status    text,
  ADD COLUMN IF NOT EXISTS marketing_ok     boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS policy_agreed_at timestamptz;

COMMENT ON COLUMN profiles.nick   IS '앱에서 부르는 이름. 인증·후기·참여자에 이건 쓴다';
COMMENT ON COLUMN profiles.name   IS '실명. 운영진 화면·서류 대조·교환권 정산에만 쓴다';
COMMENT ON COLUMN profiles.school_status    IS '재학 · 학교밖 · 졸업 · 기타';
COMMENT ON COLUMN profiles.policy_agreed_at IS '개인정보 수집·이용에 동의한 시각. 동의 기록이라 지우지 못한다';

-- 이미 가입한 사람은 닉네임이 없다. 화면에서 COALESCE(nick, name) 으로 부른다

-- ── 2. 휴대폰은 따로 ───────────────────────────────────
CREATE TABLE IF NOT EXISTS profiles_private (
  id         uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  phone      text,
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE profiles_private IS '본인과 운영진만 본다. 같은 루틴 사람에게도 안 보인다';

ALTER TABLE profiles_private ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS pp_read   ON profiles_private;
DROP POLICY IF EXISTS pp_write  ON profiles_private;
DROP POLICY IF EXISTS pp_insert ON profiles_private;
CREATE POLICY pp_read   ON profiles_private FOR SELECT TO authenticated
  USING (id = auth.uid() OR is_admin());
CREATE POLICY pp_insert ON profiles_private FOR INSERT TO authenticated
  WITH CHECK (id = auth.uid() OR is_admin());
CREATE POLICY pp_write  ON profiles_private FOR UPDATE TO authenticated
  USING (id = auth.uid() OR is_admin());

-- ── 3. 본인이 못 바꾸는 것 ─────────────────────────────
-- 동의 기록은 한 번 남으면 못 지운다. 지울 수 있으면 기록이 아니다
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
    IF OLD.birth_date       IS NOT NULL THEN NEW.birth_date       := OLD.birth_date; END IF;
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

-- ── 4. 가입할 때 넘긴 값을 옮긴다 ──────────────────────
CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger AS $$
DECLARE m jsonb := NEW.raw_user_meta_data;
BEGIN
  BEGIN
    INSERT INTO profiles (id, name, nick, role, region, birth_date,
                          school_status, marketing_ok, policy_agreed_at)
    VALUES (NEW.id,
            COALESCE(NULLIF(btrim(m->>'name'), ''), '이름없음'),
            NULLIF(btrim(m->>'nick'), ''),
            'youth',
            m->>'region',
            NULLIF(m->>'birth_date', '')::date,
            NULLIF(btrim(m->>'school_status'), ''),
            COALESCE((m->>'marketing_ok')::boolean, false),
            -- 동의 없이는 가입 화면을 통과하지 못한다. 없으면 지금 시각을 남긴다
            COALESCE(NULLIF(m->>'policy_agreed_at', '')::timestamptz, now()))
    ON CONFLICT (id) DO NOTHING;

    IF COALESCE(btrim(m->>'phone'), '') <> '' THEN
      INSERT INTO profiles_private (id, phone) VALUES (NEW.id, btrim(m->>'phone'))
      ON CONFLICT (id) DO UPDATE SET phone = EXCLUDED.phone;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    -- 여기서 막으면 가입 자체가 통째로 막힌다 (한끗루틴에서 겪었다)
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT column_name AS 칸, data_type AS 형
  FROM information_schema.columns
 WHERE table_name = 'profiles'
   AND column_name IN ('nick','school_status','marketing_ok','policy_agreed_at')
 UNION ALL
SELECT 'profiles_private.' || column_name, data_type
  FROM information_schema.columns
 WHERE table_name = 'profiles_private'
 ORDER BY 1;
