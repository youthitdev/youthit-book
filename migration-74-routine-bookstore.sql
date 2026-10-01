-- 한끗독서 마이그레이션 74
-- 루틴에 파트너 책방을 건다
--
-- 「이 루틴은 ○○서림과 함께합니다」를 모집 카드에서 보여 주려는 것이다.
-- 지금은 후원 기업(sponsor_name)만 붙는데, 그 자리에 책방 이름을 적어
-- 쓰고 계셨다. 둘은 다른 것이다 — 후원은 돈을 낸 곳이고, 파트너 책방은
-- 아이가 책을 받으러 가는 곳이다.
--
-- 【공유회 장소와도 다르다】 공유회는 책방에서 할 수도, 다른 데서 할 수도
--   있다. 장소는 meetup_place 에, 함께하는 책방은 여기에.
--
-- 【끗짱이 고른다】 후원 기업은 약속이 오간 뒤에야 붙는 것이라 운영진만
--   적지만, 함께하는 책방은 끗짱이 정하는 일이다. 다만 등록된 책방
--   중에서만 고를 수 있다 — 아이를 아무 데나 보낼 수는 없다.

ALTER TABLE routines
  ADD COLUMN IF NOT EXISTS bookstore_id bigint REFERENCES bookstores(id) ON DELETE SET NULL;

COMMENT ON COLUMN routines.bookstore_id IS '이 루틴과 함께하는 파트너 책방. 후원 기업과도, 공유회 장소와도 다르다';

CREATE INDEX IF NOT EXISTS routines_bookstore_idx ON routines (bookstore_id);

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT column_name AS 새로_생긴_칸, data_type AS 생김새
  FROM information_schema.columns
 WHERE table_name = 'routines' AND column_name = 'bookstore_id';
