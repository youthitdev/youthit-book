-- 한끗독서 마이그레이션 66
-- 「함께 읽는 책」 — 한 권을 다 같이 읽는 루틴
--
-- 지금까지 루틴은 둘이었다.
--   book   각자 읽는 책 — 청소년마다 제 책을 고른다
--   shared 함께 읽는 글 — 끗짱이 매일 글 한 편을 올린다
-- 그 사이에 제일 흔한 모양이 빠져 있었다. 독서모임이 그렇듯,
-- 끗짱이 책 한 권을 정하고 다 같이 그 책을 읽는 것.
--
-- 【칸을 새로 만들지 않는다】 함께 읽을 책은 이미 있는 kkut_book_* 에 담는다.
--   끗짱이 읽는 책이 곧 모두가 읽는 책이니 같은 자리가 맞다.
--
-- 【기존 루틴은 한 톨도 안 바뀐다】 검사 범위만 넓힌다.

ALTER TABLE routines DROP CONSTRAINT IF EXISTS routines_kind_chk;
ALTER TABLE routines ADD  CONSTRAINT routines_kind_chk
  CHECK (kind IN ('book', 'one_book', 'shared'));

COMMENT ON COLUMN routines.kind IS
  'book=각자 읽는 책 · one_book=함께 읽는 책(끗짱이 한 권을 정한다) · shared=함께 읽는 글';

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT pg_get_constraintdef(oid) AS 종류_검사
  FROM pg_constraint WHERE conname = 'routines_kind_chk';
SELECT kind AS 종류, count(*) AS 루틴수 FROM routines GROUP BY kind ORDER BY kind;
