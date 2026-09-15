-- 한끗독서 마이그레이션 04
-- 후원자 화면의 "함께한 뒤로"
--
-- 【배경】 1만원을 후원하면 운영비를 뺀 8천원이 남는데, 그 돈으로는 책 한 권을
--   살 수 없다. 그래서 "당신의 후원금이 이 책이 되었습니다" 식의 개인 추적은
--   애초에 불가능하고, 억지로 하면 % 막대 같은 초라한 화면만 남는다.
--
--   대신 금액을 쪼개지 않고, 후원자가 "합류한 시점 이후" 전체가 얼마나
--   움직였는지를 보여준다. 소액 후원자도 같은 숫자를 보고, 시간이 지날수록
--   숫자가 자라기 때문에 다시 들어올 이유가 생긴다.
--
-- ⚠️ 두 함수 모두 개인을 식별할 수 있는 값은 내보내지 않는다. 집계 수치뿐이다.

-- 합류일 이후 쌓인 것
CREATE OR REPLACE FUNCTION dokseo_since_stats(p_since timestamptz)
RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    -- 인증 1건 = 한 아이가 하루 읽은 것. '건'이 아니라 '일'로 센다
    'reading_days', COALESCE((SELECT count(*) FROM certifications
                               WHERE created_at >= p_since), 0),
    'books',        COALESCE((SELECT count(*) FROM book_purchases
                               WHERE status = 'settled' AND settled_at >= p_since), 0),
    'students',     COALESCE((SELECT count(DISTINCT user_id) FROM certifications
                               WHERE created_at >= p_since), 0)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 내가 몇 번째 후원자인지. 본인 것만 돌려준다
CREATE OR REPLACE FUNCTION dokseo_my_seq()
RETURNS int AS $$
  SELECT seq::int FROM (
    SELECT user_id, row_number() OVER (ORDER BY created_at, id) AS seq
      FROM sponsors) t
   WHERE t.user_id = auth.uid();
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_since_stats(timestamptz) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_my_seq()                 TO authenticated;
