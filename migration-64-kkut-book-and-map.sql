-- 한끗독서 마이그레이션 64
-- 끗짱이 읽는 책의 제목, 그리고 공유회 장소의 좌표
--
-- 【끗짱의 책】 지금까지는 사진 한 장뿐이었다. 아이가 신청할 때 자기 책을
--   검색해 고르는데(53), 정작 끗짱의 책은 손으로도 못 적었다.
--   같은 검색을 붙이고, 사진은 그대로 남긴다 — 실제로 들고 있다는 표시다.
--
-- 【공유회 장소】 meetup_place 는 「속초 당신의강릉 2층」 같은 사람 말이었다.
--   그것만으로는 아이가 찾아가지 못한다. 주소와 좌표를 따로 받아
--   카카오맵 길찾기로 바로 보낸다.
--   좌표는 없어도 된다 — 학교 도서관, 누구네 집처럼 지도에 없는 곳도 있다.
--   그럴 땐 예전처럼 장소 이름만 보인다.

ALTER TABLE routines
  ADD COLUMN IF NOT EXISTS kkut_book_title     text,
  ADD COLUMN IF NOT EXISTS kkut_book_isbn      text,
  ADD COLUMN IF NOT EXISTS kkut_book_authors   text,
  ADD COLUMN IF NOT EXISTS kkut_book_publisher text,
  ADD COLUMN IF NOT EXISTS meetup_address text,
  ADD COLUMN IF NOT EXISTS meetup_lat     double precision,
  ADD COLUMN IF NOT EXISTS meetup_lng     double precision;

COMMENT ON COLUMN routines.kkut_book_title     IS '끗짱이 읽는 책 제목';
COMMENT ON COLUMN routines.kkut_book_isbn      IS '끗짱 책의 ISBN-13 (검색으로 고른 경우)';
COMMENT ON COLUMN routines.kkut_book_authors   IS '끗짱 책의 지은이';
COMMENT ON COLUMN routines.kkut_book_publisher IS '끗짱 책의 펴낸곳';
COMMENT ON COLUMN routines.meetup_address IS '공유회 장소의 도로명 주소 (검색으로 고른 경우)';
COMMENT ON COLUMN routines.meetup_lat     IS '공유회 장소 위도 — 길찾기에 쓴다';
COMMENT ON COLUMN routines.meetup_lng     IS '공유회 장소 경도 — 길찾기에 쓴다';

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT column_name AS 새로_생긴_칸
  FROM information_schema.columns
 WHERE table_name = 'routines'
   AND column_name IN ('kkut_book_title','kkut_book_isbn','kkut_book_authors',
                       'kkut_book_publisher','meetup_address','meetup_lat','meetup_lng')
 ORDER BY column_name;
