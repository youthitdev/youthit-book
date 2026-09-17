-- 한끗독서 마이그레이션 29
-- 루틴 후기에 7일 기한을 건다
--
-- 루틴이 끝나고 한참 뒤에 몰아서 쓰면 그건 기록이 아니라 포인트 수확이다.
-- 기한을 지나면 못 쓴다. 30P 도 못 받는다.
--
-- 기준일은 end_date 다. 끗짱이나 운영진이 일찍 종료해도 end_date + 7 까지는
-- 열어둔다 — 아이가 갑자기 닫혔다고 손해 보면 안 된다.
--
-- ⚠️ 이미 끝난 지 오래인 루틴은 기한이 이미 지나 있다. 그러면 지금 참여 중인
--    아이들이 손쓸 새도 없이 기회를 잃는다. 그래서 이 기능을 켜는 날부터
--    최소 7일은 누구에게나 열어둔다 (review_grace_from).

ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS review_deadline_days int  NOT NULL DEFAULT 7,
  ADD COLUMN IF NOT EXISTS review_grace_from    date NOT NULL DEFAULT CURRENT_DATE;

COMMENT ON COLUMN dokseo_settings.review_deadline_days IS '루틴이 끝나고 후기를 쓸 수 있는 날 수';
COMMENT ON COLUMN dokseo_settings.review_grace_from   IS '이 기능을 켠 날. 그 전에 끝난 루틴도 이 날부터 기한을 센다';

-- 마감일 하나로 정리해두고 서버와 화면이 같은 답을 보게 한다
CREATE OR REPLACE FUNCTION review_due(p_routine bigint)
RETURNS date AS $$
  SELECT GREATEST(r.end_date, s.review_grace_from)
         + COALESCE(s.review_deadline_days, 7)
    FROM routines r, dokseo_settings s
   WHERE r.id = p_routine AND s.id = 1;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION review_due(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION review_due(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION check_review_insert() RETURNS trigger AS $$
DECLARE v_due date; v_today date;
BEGIN
  -- SQL 편집기에서는 auth.uid() 가 없다. 운영진도 통과시킨다
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;
  IF NEW.kind <> 'routine' THEN RETURN NEW; END IF;   -- 책 후기는 기한이 없다

  v_today := (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_due   := review_due(NEW.routine_id);

  IF v_due IS NOT NULL AND v_today > v_due THEN
    RAISE EXCEPTION '후기 쓰는 기한이 지났어요 (%까지였어요)', to_char(v_due, 'MM월 DD일');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS reviews_deadline ON reviews;
CREATE TRIGGER reviews_deadline BEFORE INSERT ON reviews
  FOR EACH ROW EXECUTE FUNCTION check_review_insert();

NOTIFY pgrst, 'reload schema';

-- ↓ 지금 열려 있는 루틴별 마감일. 줄이 나와야 성공이다
SELECT r.id AS 루틴, r.title AS 이름, r.end_date AS 종료일,
       review_due(r.id) AS 후기마감,
       review_due(r.id) - (now() AT TIME ZONE 'Asia/Seoul')::date AS 남은날
  FROM routines r ORDER BY r.id;
