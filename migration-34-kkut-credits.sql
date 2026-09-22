-- 한끗독서 마이그레이션 34
-- 끗짱 적립금 — 아이들이 읽은 날, 유스보이스가 하루 100원을 책값으로 낸다
--
-- 끗짱은 지금 아무것도 못 받는다. 아이들을 챙기고 루틴을 끌고 가는데 화면에
-- 남는 게 없다. 그렇다고 끗짱에게 돈을 주면 자원활동의 대가가 되어버린다.
--
-- 그래서 카카오같이가치와 같은 구조로 간다. 좋아요를 누른 사람이 기부자가
-- 아니라, 기업이 걸어둔 돈을 사용자가 풀어주는 것이다. 여기서도 마찬가지다.
--
--   기부하는 주체는 유스보이스다. 끗짱은 그 돈을 풀어주는 계기다.
--   돈은 끗짱에게 가지 않는다. 아이들 책으로 간다.
--   그래서 대가성이 아니고, 기부금영수증 문제도 생기지 않는다.
--
-- ⚠️ 문구에서 주어는 반드시 유스보이스여야 한다.
--    「끗짱님이 기부했습니다」 (X)  「유스보이스가 냈습니다」 (O)
--
-- 지금은 유스보이스 자체 예산이다. 나중에 기업 후원이 붙으면 funder 만
-- 바꾸면 된다 — 적립 줄마다 누가 냈는지 남겨두므로 섞여도 구분된다.

-- ── 1. 설정 ────────────────────────────────────────────
ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS kkut_credit_per_day int  NOT NULL DEFAULT 100,
  ADD COLUMN IF NOT EXISTS kkut_credit_funder  text NOT NULL DEFAULT '유스보이스';
COMMENT ON COLUMN dokseo_settings.kkut_credit_per_day IS '아이가 읽은 하루당 끗짱 적립액(원)';
COMMENT ON COLUMN dokseo_settings.kkut_credit_funder  IS '실제로 내는 곳. 기업 후원이 붙으면 여기를 바꾼다';

-- ── 2. 적립 내역 ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS kkut_credits (
  user_id    uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,  -- 끗짱
  routine_id bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  day        date   NOT NULL,
  amount     int    NOT NULL CHECK (amount > 0),
  funder     text   NOT NULL DEFAULT '유스보이스',
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, routine_id, day)
);
CREATE INDEX IF NOT EXISTS kkut_credits_mine ON kkut_credits (user_id, day DESC);
COMMENT ON TABLE kkut_credits IS
  '끗짱이 함께한 날에 유스보이스가 낸 책값. 끗짱의 돈이 아니라 끗짱이 계기가 된 돈이다';

-- ── 3. 아이가 인증하면 그날치가 쌓인다 ──────────────────
-- 루틴이 열려만 있고 아무도 안 읽은 날은 안 쌓인다. 아이가 읽은 날,
-- 그 곁에 끗짱이 있었다는 뜻이다
CREATE OR REPLACE FUNCTION accrue_kkut_credit() RETURNS trigger AS $$
DECLARE v_lead uuid; v_amt int; v_funder text;
BEGIN
  SELECT r.led_by INTO v_lead FROM routines r WHERE r.id = NEW.routine_id;
  IF v_lead IS NULL OR v_lead = NEW.user_id THEN RETURN NEW; END IF;  -- 자기 루틴에 자기가
  IF NOT COALESCE((SELECT can_lead FROM profiles WHERE id = v_lead), false) THEN
    RETURN NEW;                                   -- 운영진이 만든 루틴은 안 쌓는다
  END IF;

  SELECT COALESCE(kkut_credit_per_day, 100), COALESCE(kkut_credit_funder, '유스보이스')
    INTO v_amt, v_funder FROM dokseo_settings WHERE id = 1;

  INSERT INTO kkut_credits (user_id, routine_id, day, amount, funder)
  VALUES (v_lead, NEW.routine_id, NEW.cert_date, GREATEST(v_amt, 1), v_funder)
  ON CONFLICT DO NOTHING;                         -- 하루에 한 번. 몇 명이 읽었든
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS certs_kkut_credit ON certifications;
CREATE TRIGGER certs_kkut_credit AFTER INSERT ON certifications
  FOR EACH ROW EXECUTE FUNCTION accrue_kkut_credit();

-- ── 4. 읽기 ────────────────────────────────────────────
ALTER TABLE kkut_credits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS kcredits_read ON kkut_credits;
CREATE POLICY kcredits_read ON kkut_credits FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin());

-- 내 적립과 끗짱 전체 합계. 혼자서는 1,500원이라 허전하다.
-- 모이면 책 한 권이 된다는 걸 같이 보여준다
CREATE OR REPLACE FUNCTION kkut_credit_summary()
RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'mine',      COALESCE((SELECT sum(amount) FROM kkut_credits WHERE user_id = auth.uid()), 0),
    'my_days',   COALESCE((SELECT count(*)    FROM kkut_credits WHERE user_id = auth.uid()), 0),
    'total',     COALESCE((SELECT sum(amount) FROM kkut_credits), 0),
    'per_day',   COALESCE((SELECT kkut_credit_per_day FROM dokseo_settings WHERE id = 1), 100),
    'funder',    COALESCE((SELECT kkut_credit_funder  FROM dokseo_settings WHERE id = 1), '유스보이스'),
    'book_price',COALESCE((SELECT round(avg(amount))::int FROM book_purchases
                            WHERE status = 'settled' AND amount IS NOT NULL), 16500)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION kkut_credit_summary() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION kkut_credit_summary() TO authenticated;

-- 월간 보고에 붙일 한 달치
CREATE OR REPLACE FUNCTION kkut_credit_month(p_year int, p_month int)
RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'amount', COALESCE(sum(c.amount), 0),
    'days',   count(*),
    'kkuts',  count(DISTINCT c.user_id),
    'rows',   COALESCE(jsonb_agg(DISTINCT jsonb_build_object('name', p.name)), '[]'::jsonb))
    FROM kkut_credits c JOIN profiles p ON p.id = c.user_id
   WHERE c.day >= make_date(p_year, p_month, 1)
     AND c.day <  (make_date(p_year, p_month, 1) + interval '1 month')::date;
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION kkut_credit_month(int, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION kkut_credit_month(int, int) TO authenticated;

-- ── 5. 지금까지의 기록에도 소급해서 쌓는다 ──────────────
INSERT INTO kkut_credits (user_id, routine_id, day, amount, funder)
SELECT r.led_by, c.routine_id, c.cert_date,
       COALESCE((SELECT kkut_credit_per_day FROM dokseo_settings WHERE id = 1), 100),
       COALESCE((SELECT kkut_credit_funder  FROM dokseo_settings WHERE id = 1), '유스보이스')
  FROM certifications c
  JOIN routines r ON r.id = c.routine_id
  JOIN profiles p ON p.id = r.led_by
 WHERE r.led_by IS NOT NULL AND r.led_by <> c.user_id AND p.can_lead
 GROUP BY r.led_by, c.routine_id, c.cert_date
ON CONFLICT DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ↓ 끗짱별 적립. 줄이 나와야 성공이다
SELECT p.name AS 끗짱, count(*) AS 함께한날, sum(c.amount) AS 적립액, c.funder AS 낸곳
  FROM kkut_credits c JOIN profiles p ON p.id = c.user_id
 GROUP BY p.name, c.funder ORDER BY 3 DESC;
