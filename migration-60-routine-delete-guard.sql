-- 한끗독서 마이그레이션 60
-- 루틴을 지울 때, 돈이 오간 기록은 지키게 한다
--
-- 루틴을 지우면 딸린 것이 전부 같이 지워진다 (ON DELETE CASCADE):
--   참여 · 인증 · 댓글 · 읽는 책 · 후기 · 콕 · 공유글 · **책 구매**
--
-- 【마지막 하나가 문제다】 정산이 끝난 구매는 유스보이스가 책방에 **실제로 돈을
--   보낸 기록**이다. 기부금 사용명세에 들어가는 자료라 지우면 안 된다.
--   관리자 화면에서든 SQL 편집기에서든, 어디서 지우든 막히도록 표에 건다.
--
-- 지우고 싶으면 그 구매를 먼저 정리해야 한다 — 그러려면 사람이 한 번 더
-- 생각하게 된다. 그게 이 문턱의 목적이다.

CREATE OR REPLACE FUNCTION guard_routine_delete() RETURNS trigger AS $$
DECLARE n int; v_amt int;
BEGIN
  SELECT count(*), COALESCE(sum(amount), 0) INTO n, v_amt
    FROM book_purchases
   WHERE routine_id = OLD.id AND status = 'settled';

  IF n > 0 THEN
    RAISE EXCEPTION
      '이 루틴에는 정산이 끝난 구매가 % 건(%원) 있습니다. 돈이 오간 기록이라 지울 수 없어요.',
      n, to_char(v_amt, 'FM999,999,999');
  END IF;

  RETURN OLD;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_del_guard ON routines;
CREATE TRIGGER routines_del_guard BEFORE DELETE ON routines
  FOR EACH ROW EXECUTE FUNCTION guard_routine_delete();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT tgname AS 트리거, c.relname AS 표, p.proname AS 함수
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc  p ON p.oid = t.tgfoid
 WHERE tgname = 'routines_del_guard';
