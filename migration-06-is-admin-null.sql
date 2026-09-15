-- 한끗독서 마이그레이션 06  ⚠️ 보안 수정. 다른 것보다 먼저 실행할 것
--
-- 【문제】 is_admin() 이 이렇게 돼 있었다.
--     SELECT auth.email() IN ('dev@...', 'yv@...')
--   로그인하지 않은 사람은 auth.email() 이 NULL 이고,
--   SQL 에서 NULL IN (...) 은 false 가 아니라 NULL 이다.
--
--   그래서 settle_book_purchase() 의
--     IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'
--   가 IF NOT NULL → IF NULL 이 되고, plpgsql 은 NULL 조건을 거짓으로 보므로
--   예외를 던지지 않고 그냥 통과한다. 익명 사용자가 정산을 실행할 수 있었다.
--   (실제로 익명 키로 호출해 보니 권한 오류 대신 다음 단계로 넘어갔다)
--
--   RLS 정책들은 USING (is_admin()) 형태라 NULL 이 행을 걸러내는 쪽으로
--   작동해서 무사했다. 하지만 같은 지뢰가 언제든 다시 밟힐 수 있으므로
--   함수 자체를 고친다.

CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean AS $$
  SELECT COALESCE(auth.email() IN ('dev@youthvoice.or.kr', 'yv@youthvoice.or.kr'), false);
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 한 겹 더. 함수를 만들면 PUBLIC 에 EXECUTE 가 기본으로 붙기 때문에
-- authenticated 에만 GRANT 해도 익명이 호출할 수 있다. 명시적으로 회수한다
REVOKE EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) TO authenticated;

REVOKE EXECUTE ON FUNCTION dokseo_balance(uuid, bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_balance(uuid, bigint) TO authenticated;

REVOKE EXECUTE ON FUNCTION dokseo_my_seq() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_my_seq() TO authenticated;
