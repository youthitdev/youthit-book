-- 한끗독서 마이그레이션 65
-- 공유회 상세 위치
--
-- 카카오맵은 건물까지만 데려다준다. 「2층 세미나실」, 「정문 옆 별관」 같은
-- 마지막 한 걸음은 지도에 없다. 도착해서 헤매는 건 아이 몫이 된다.
--
-- 【왜 안내할 말에 안 적나】 meetup_note 는 카드 맨 아래 문단이라
--   「준비물: 필기구」 같은 것과 섞인다. 급히 찾아가는 아이 눈에는 안 들어온다.
--   주소 바로 아래 한 줄로 서야 눈에 든다.
--
-- 【왜 길찾기에 안 넣나】 카카오맵은 이걸 못 알아듣는다.
--   넣으면 되레 엉뚱한 데로 보낸다. 좌표는 건물, 이 칸은 사람이 읽는 몫이다.

ALTER TABLE routines
  ADD COLUMN IF NOT EXISTS meetup_detail text;

COMMENT ON COLUMN routines.meetup_detail IS '공유회 상세 위치 — 층·호실처럼 지도에 없는 마지막 한 걸음';

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT column_name AS 새로_생긴_칸
  FROM information_schema.columns
 WHERE table_name = 'routines' AND column_name = 'meetup_detail';
