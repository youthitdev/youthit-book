-- 한끗독서 마이그레이션 03
-- 로그인하지 않아도 루틴을 둘러볼 수 있게 함
--
-- 【배경】 익명 사용자는 routines / bookstores / dokseo_settings 만 읽을 수 있다.
--   청소년의 이름·사진·인증 기록은 로그인해야 보이는 게 맞으므로 그대로 둔다.
--   문제는 참여 인원 수까지 못 읽어서 모든 루틴이 "0/8명"으로 보인다는 것.
--   그래서 인원 "수"만 돌려주는 함수를 따로 연다. 누가 참여하는지는 나가지 않는다.

CREATE OR REPLACE FUNCTION routine_people_count()
RETURNS TABLE (routine_id bigint, people bigint) AS $$
  SELECT routine_id, count(*)
    FROM routine_participants
   WHERE status = 'approved'
   GROUP BY routine_id;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION routine_people_count() TO anon, authenticated;
