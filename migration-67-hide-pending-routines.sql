-- 한끗독서 마이그레이션 67
-- 승인 전 루틴은 만든 사람과 운영진에게만 보인다
--
-- 【무엇이 잘못됐나】 routines_read 가 USING (true) 였다. 끗짱이 막 만들어
--   아직 운영진이 열어주지 않은 루틴(status='pending')을 누구나 읽을 수 있었다.
--   앱 화면의 「지금 모집 중인 루틴」에도 그대로 끼어들었다.
--
-- 【왜 서버에서도 막나】 앱에서 거르는 것만으로는 화면에서만 안 보일 뿐이다.
--   열어주기 전의 글은 운영진이 아직 읽지 않은 글이다. 서버가 안 내줘야 한다.
--
-- 【누가 봐야 하나】
--   · 만든 끗짱 — 자기 루틴의 승인 대기 카드를 봐야 한다
--   · 운영진 — 승인할 것을 봐야 한다
--   · 그 밖에는 아무도. 손님(비로그인)도 마찬가지다.
--
-- 열린 뒤(recruit·active·done)는 지금처럼 모두에게 열려 있다 —
-- 로그인 전에도 둘러볼 수 있어야 하기 때문이다.

DROP POLICY IF EXISTS routines_read ON routines;
CREATE POLICY routines_read ON routines FOR SELECT USING (
  COALESCE(status, 'pending') <> 'pending'
  OR led_by = auth.uid()
  OR is_admin()
);

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT pg_get_expr(polqual, polrelid) AS 읽기_조건
  FROM pg_policy WHERE polname = 'routines_read';
SELECT status AS 상태, count(*) AS 루틴수 FROM routines GROUP BY status ORDER BY status;
