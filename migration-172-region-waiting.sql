-- 한끗독서 마이그레이션 172
-- 「○○ 책방을 N명의 청소년이 기다리고 있어요」 — 같은 시·군·구에 사는 청소년 수 (2026-11-13 사용자)
--
-- 【하는 일】 region_waiting(지역) — 그 시·군·구(예: 「서울 강동구」)에 사는 청소년 회원 수를 돌려준다.
--   · 가입 화면은 로그인 전이라 누구나 부를 수 있게 연다. 이름·연락처는 주지 않고 숫자 하나만 준다.
--   · 청소년 회원만 센다. 끗짱·어른·탈퇴한 회원은 뺀다.
--   · 「서산시」와 「서산」처럼 끝의 시·군·구 글자만 다른 표기는 같은 곳으로 본다.
--   · 3명 미만이어도 그대로 돌려준다 (1명도 보여 주기로 했다).
-- 되돌리려면: DROP FUNCTION region_waiting(text);  (앱은 함수가 없으면 문구를 보이지 않는다)
-- ⚠️ 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION region_waiting(p_region text) RETURNS int AS $$
  SELECT count(*)::int
    FROM profiles p
   WHERE NULLIF(btrim(COALESCE(p_region, '')), '') IS NOT NULL
     AND p.withdrawn_at IS NULL
     AND COALESCE(p.role, 'youth') = 'youth'
     AND NOT COALESCE(p.can_lead, false)
     AND regexp_replace(regexp_replace(btrim(COALESCE(p.region, '')), '\s+', ' ', 'g'), '(시|군|구)$', '')
       = regexp_replace(regexp_replace(btrim(p_region), '\s+', ' ', 'g'), '(시|군|구)$', '')
$$ LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION region_waiting(text) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION region_waiting(text) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 함수 1 / 로그인 없는 사람도 부를 수 있음 true / 숫자가 나옴(지역마다 다름)
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'region_waiting')                              AS 함수_1이어야,
       has_function_privilege('anon', 'region_waiting(text)', 'EXECUTE')                            AS 익명_호출_true여야,
       region_waiting('서울 강동구')                                                                 AS 서울_강동구_청소년수;
