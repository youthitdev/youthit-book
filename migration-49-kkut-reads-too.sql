-- ────────────────────────────────────────────────────────────────────
-- 49. 끗짱도 아이들과 함께 읽는다
--
--   적립금이 「아이가 읽은 날」에 붙어 있었다. 끗짱이 직접 할 수 있는 일이
--   아니라 동기가 되지 않는다. 원래 뜻은 「끗짱도 읽고, 읽은 만큼 쌓인다」였다.
--
--   그런데 33 번에서 어른의 인증을 통째로 막아 뒀다. 그 트리거가
--   「어른은 책을 못 받는다」를 지키는 **유일한 서버 장치**이기도 했다 —
--   인증이 없으면 포인트가 없고, 포인트가 없으면 교환권도 없으니까.
--
--   그래서 장치를 옮긴다. 막을 자리는 인증이 아니라 **돈이 나가는 자리**다.
--     · 인증: 끗짱은 자기가 맡은 루틴에서 할 수 있다
--     · 책 수령: role='youth' 만. 도서기금은 청소년에게 쓰는 돈이다
--
--   청소년은 인증 → 10P → 교환권 → 책
--   끗짱은  인증 → 100원 → 유스보이스가 아이들 책값으로
-- ────────────────────────────────────────────────────────────────────

-- ── 1. 끗짱은 자기 루틴에서 인증할 수 있다 ─────────────
CREATE OR REPLACE FUNCTION check_cert_youth() RETURNS trigger AS $$
DECLARE v_role text; v_lead uuid;
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;

  SELECT role INTO v_role FROM profiles WHERE id = NEW.user_id;
  IF COALESCE(v_role, 'youth') = 'youth' THEN RETURN NEW; END IF;

  -- 어른이면 자기가 맡은 루틴에서만. 남의 루틴에 끼어들 수는 없다
  SELECT led_by INTO v_lead FROM routines WHERE id = NEW.routine_id;
  IF v_lead IS DISTINCT FROM NEW.user_id THEN
    RAISE EXCEPTION '맡은 루틴에서만 인증할 수 있어요';
  END IF;
  IF NOT COALESCE((SELECT can_lead FROM profiles WHERE id = NEW.user_id), false) THEN
    RAISE EXCEPTION '청소년만 인증할 수 있어요';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 2. 책은 청소년만 받는다 ────────────────────────────
-- 인증을 열었으니 이 장치가 이제 혼자 그 일을 한다
CREATE OR REPLACE FUNCTION check_purchase_verified() RETURNS trigger AS $$
DECLARE v text; v_role text;
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;

  SELECT verify_status, role INTO v, v_role FROM profiles WHERE id = NEW.user_id;
  IF COALESCE(v_role, 'youth') <> 'youth' THEN
    RAISE EXCEPTION '도서기금은 청소년에게 쓰는 돈이에요';
  END IF;
  IF COALESCE(v, 'none') <> 'approved' THEN
    RAISE EXCEPTION '청소년 확인이 끝나야 책을 받을 수 있어요';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 3. 적립은 끗짱이 읽은 날에 ─────────────────────────
CREATE OR REPLACE FUNCTION accrue_kkut_credit() RETURNS trigger AS $$
DECLARE v_lead uuid; v_amt int; v_funder text;
BEGIN
  SELECT r.led_by INTO v_lead FROM routines r WHERE r.id = NEW.routine_id;
  -- 맡은 사람이 읽은 날에만 쌓인다. 아이들이 읽은 날이 아니다 —
  -- 끗짱이 직접 할 수 있는 일이어야 동기가 된다
  IF v_lead IS NULL OR v_lead <> NEW.user_id THEN RETURN NEW; END IF;
  IF NOT COALESCE((SELECT can_lead FROM profiles WHERE id = v_lead), false) THEN
    RETURN NEW;                                   -- 운영진이 만든 루틴은 안 쌓는다
  END IF;

  SELECT COALESCE(kkut_credit_per_day, 100), COALESCE(kkut_credit_funder, '유스보이스')
    INTO v_amt, v_funder FROM dokseo_settings WHERE id = 1;

  INSERT INTO kkut_credits (user_id, routine_id, day, amount, funder)
  VALUES (v_lead, NEW.routine_id, NEW.cert_date, GREATEST(v_amt, 1), v_funder)
  ON CONFLICT DO NOTHING;                         -- 하루에 한 번
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 4. 옛 규칙으로 쌓인 것 ─────────────────────────────
-- 아이들이 읽은 날로 쌓인 기록이다. 끗짱이 읽어서 번 게 아니라
-- 지우는 게 맞지만, 이미 「3,700원」을 본 사람이 있다. 지우지 않고
-- 표시만 남긴다 — 나중에 왜 숫자가 다른지 따질 일을 없앤다
ALTER TABLE kkut_credits ADD COLUMN IF NOT EXISTS legacy boolean NOT NULL DEFAULT false;
UPDATE kkut_credits c SET legacy = true
 WHERE NOT EXISTS (SELECT 1 FROM certifications x
                    WHERE x.routine_id = c.routine_id AND x.user_id = c.user_id
                      AND x.cert_date = c.day);
COMMENT ON COLUMN kkut_credits.legacy IS '49 번 전에 「아이가 읽은 날」로 쌓인 것';

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT p.name AS 끗짱,
       count(*) FILTER (WHERE NOT c.legacy) AS 본인이읽어서,
       count(*) FILTER (WHERE c.legacy)     AS 옛규칙,
       sum(c.amount) AS 합계
  FROM kkut_credits c JOIN profiles p ON p.id = c.user_id
 GROUP BY p.name ORDER BY p.name;
