-- 한끗독서 마이그레이션 71
-- 회원 목록에서 포인트를 한 번에 본다
--
-- 운영진 화면의 「청소년 확인」은 사람 목록이다. 거기서 누가 얼마나 모았는지
-- 보려면 사람마다 dokseo_points() 를 불러야 했다. 다섯 명이면 몰라도
-- 쉰 명이면 쉰 번이다.
--
-- 【다시 계산하지 않는다】 인증·댓글·이정표·후기·공유회가 다 섞여 있어
--   따로 세면 두 벌이 생기고, 두 벌은 언젠가 어긋난다. 이미 있는
--   dokseo_points() 를 사람 수만큼 돌려서 한 번에 돌려줄 뿐이다.
--
-- 【운영진만】 남의 포인트를 보는 일이다.
--
-- ⚠️ SQL 편집기에서는 auth.uid() 가 비어 있어 is_admin() 이 거짓이 된다.
--   그냥 NOT is_admin() 으로 막으면 아래 확인 SELECT 가 터지고, 붙여넣기는
--   한 트랜잭션이라 함수까지 같이 되돌아간다. 집 안의 다른 함수들처럼
--   「로그인한 사람인데 운영진이 아니면」으로 적는다.
--   밖에서는 anon 에게 EXECUTE 를 안 줬으니 로그인 없이는 아예 못 부른다.

CREATE OR REPLACE FUNCTION dokseo_points_all()
RETURNS TABLE(user_id uuid, points int, earned int, used int, remain int) AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  RETURN QUERY
    SELECT p.id,
           (d ->> 'points')::int,
           (d ->> 'earned')::int,
           (d ->> 'used')::int,
           (d ->> 'left')::int
      FROM profiles p
      CROSS JOIN LATERAL dokseo_points(p.id) AS d
     WHERE COALESCE(p.role, 'youth') = 'youth';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION dokseo_points_all() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points_all() TO authenticated;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT count(*) AS 청소년수, COALESCE(sum(points), 0) AS 포인트합
  FROM dokseo_points_all();
