-- 한끗독서 마이그레이션 171
-- 책방 정보 창에 책방 사진 (2026-11-13 사용자: 영업시간 줄 오른쪽에 사진, 없으면 집 이모지)
--
-- 【하는 일】 bookstores.photo_url 칸을 둔다. 관리자 「파트너 책방」 수정 창에서 운영진이 사진을 올리면
--   모임 대표 사진과 같은 공개 저장소(routine-covers)에 올라가고 그 주소가 여기 담긴다.
--   청소년이 나오는 사진이 아니라 책방 가게 사진이라 공개 저장소를 쓴다.
--   칸이 비어 있으면 앱은 집 이모지를 보여 준다.
-- 되돌리려면: 관리자 수정 창에서 사진 「빼기」 (칸을 비운다). 칸 자체를 지우려면 ALTER TABLE bookstores DROP COLUMN photo_url;
-- ⚠️ 여러 번 돌려도 된다.

ALTER TABLE bookstores ADD COLUMN IF NOT EXISTS photo_url text;
COMMENT ON COLUMN bookstores.photo_url IS '책방 가게 사진 주소 (routine-covers 공개 저장소). 비면 앱은 집 이모지';

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무것도 바꾸지 않는다. 기대: 1
SELECT count(*) AS 사진칸_1이어야
  FROM information_schema.columns
 WHERE table_name = 'bookstores' AND column_name = 'photo_url';
