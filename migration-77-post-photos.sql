-- 한끗독서 마이그레이션 77
-- 오늘 글에 사진을 붙인다
--
-- 10월 책방채움 루틴은 시 세 편을 함께 읽고 그중 한 편을 골라 필사한다.
-- 시는 줄바꿈과 여백이 곧 글이라, 옮겨 적으면 모양이 무너진다.
-- 책에서 찍은 사진을 그대로 붙일 수 있게 한다.
--
-- 【글은 그대로 필수】 사진만 올리고 글을 비우면 알림에 담을 말이 없고,
--   사진을 못 보는 상황에서는 아무것도 안 남는다. 짧게라도 적는다.
--
-- 【세 장까지】 인증 사진과 같은 수다. 더 올릴 일이면 글을 나누는 게 맞다.

ALTER TABLE routine_posts
  ADD COLUMN IF NOT EXISTS photo_urls text[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN routine_posts.photo_urls IS '오늘 글에 붙인 사진. 시처럼 모양이 곧 글인 것을 그대로 보여주려는 것';

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT column_name AS 새로_생긴_칸, data_type AS 생김새
  FROM information_schema.columns
 WHERE table_name = 'routine_posts' AND column_name = 'photo_urls';
