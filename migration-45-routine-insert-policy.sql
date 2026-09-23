-- ────────────────────────────────────────────────────────────────────
-- 45. 끗짱이 루틴을 못 만들던 것
--
--   "new row violates row-level security policy for table routines"
--
--   33 번에서 역할을 두 축으로 갈랐다 — role 은 youth|adult 가 되고
--   끗짱 여부는 can_lead 로 옮겼다. 그때 트리거와 is_approved_kkut() 은
--   고쳤는데, **INSERT 정책 하나를 빼먹었다.**
--
--     AND EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'kkutjjang')
--
--   role 에 'kkutjjang' 이 더는 없으니 이 줄은 항상 거짓이다.
--   그래서 승인된 끗짱도, 관리자도 아닌 사람은 전부 막혔다.
--
--   ⚠️ 교훈: 역할 판정을 여러 군데서 따로 하면 한 군데를 반드시 빠뜨린다.
--   판정은 is_approved_kkut() 하나로만 한다. 정책도 그걸 부른다.
-- ────────────────────────────────────────────────────────────────────

DROP POLICY IF EXISTS routines_kkutjjang_insert ON routines;
CREATE POLICY routines_kkutjjang_insert ON routines FOR INSERT TO authenticated
  WITH CHECK (
    -- 트리거(check_routine_write)가 BEFORE INSERT 에서 led_by 를 채운다.
    -- WITH CHECK 은 트리거 뒤에 보므로 클라이언트가 안 보내도 통과한다
    led_by = auth.uid()
    AND is_approved_kkut()
  );

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 정책 본문에 'kkutjjang' 이 남아 있으면 안 된다
SELECT polname AS 정책,
       pg_get_expr(polwithcheck, polrelid) AS 조건,
       (pg_get_expr(polwithcheck, polrelid) LIKE '%kkutjjang%') AS 옛역할남음
  FROM pg_policy
 WHERE polrelid = 'routines'::regclass AND polcmd = 'a';
