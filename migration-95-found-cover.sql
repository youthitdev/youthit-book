-- 한끗독서 마이그레이션 95
-- 책 검색에서 고른 표지를 따로 적어 둔다 (MY 책장에 검색 표지를 먼저 보이려고)
--
-- 【왜】 청소년은 참여할 때 책 사진을 찍어 올린다(손에 들었다는 확인). 그 사진은 그대로 받되,
--   MY 책장은 검색한 표지가 있으면 그걸 먼저 보인다 — 같은 책이 같은 모양으로 모이고 깔끔하다.
--   routine_books.cover_url 은 아이가 찍은 사진이라 섞지 않고 새 칸을 둔다.
-- 【옛 기록】 이미 담긴 책은 이 칸이 비어 있다. 그대로 찍은 사진이 보인다.
--   카카오가 준 주소를 그대로 건다 — 우리 저장소에 옮겨 담지 않는다.

ALTER TABLE routine_books ADD COLUMN IF NOT EXISTS found_cover_url text;
COMMENT ON COLUMN routine_books.found_cover_url IS '책 검색에서 고른 표지 주소. 손으로 적었으면 NULL';

NOTIFY pgrst, 'reload schema';

SELECT column_name FROM information_schema.columns
 WHERE table_name = 'routine_books' AND column_name = 'found_cover_url';
