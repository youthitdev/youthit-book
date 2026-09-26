-- 한끗독서 마이그레이션 53
-- 책 제목을 검색해서 넣는다 — 표지 사진은 그대로 둔다
--
-- 【무엇을 고치나】
--   book_title 이 자유 텍스트라 같은 책이 갈라진다.
--     「긴 이별을 위한 짧은 편지」 / 「긴이별을위한짧은편지」 / 「긴 이별을…(개정판)」
--   지금 화면은 이 제목 문자열로 조인한다 — booksOf() · pageOf() · dropBook().
--   제목이 정규화되면 그 조인들이 저절로 튼튼해진다. 이게 이 작업의 요점이다.
--
-- 【표지는 안 건드린다】
--   cover_url 은 아이가 직접 찍은 사진이다. 그게 '정말 그 책을 들고 있었다' 의
--   증거라서 검색 표지로 갈아끼우지 않는다. 표지가 나중에 필요해지면
--   isbn 하나로 언제든 가져올 수 있으니 지금 받아둘 이유도 없다.
--
-- 【옛 기록은 그대로 둔다】
--   이미 들어간 자유 텍스트 제목을 소급해 고치지 않는다. 고치면 인증·포인트가
--   매달린 조인이 끊어진다. 새로 넣는 책부터 정규화된다.

ALTER TABLE routine_books
  ADD COLUMN IF NOT EXISTS isbn      text,
  ADD COLUMN IF NOT EXISTS authors   text,
  ADD COLUMN IF NOT EXISTS publisher text;

COMMENT ON COLUMN routine_books.isbn      IS '카카오 책 검색에서 고른 ISBN-13. 손으로 적었으면 NULL';
COMMENT ON COLUMN routine_books.authors   IS '저자. 쉼표로 이음';
COMMENT ON COLUMN routine_books.publisher IS '출판사';

-- 월간보고·후원자 보고에 쓸 '아이들이 읽은 책'. isbn 이 있는 것만 묶인다.
-- 손으로 적은 책은 제목 그대로 한 줄씩 남는다 — 빠뜨리지 않기 위해서다
CREATE INDEX IF NOT EXISTS routine_books_isbn_idx
  ON routine_books (isbn) WHERE isbn IS NOT NULL;

SELECT column_name, data_type
  FROM information_schema.columns
 WHERE table_name = 'routine_books'
 ORDER BY ordinal_position;
