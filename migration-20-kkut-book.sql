-- 한끗독서 마이그레이션 20
-- 끗짱이 읽는 책 사진
--
-- 청소년은 참여할 때 자기가 읽을 책 사진을 필수로 올린다. 그런데 끗짱은
-- 댓글만 달아서, 실제로 같이 읽는지가 아이들 눈에 안 보인다. 그러면
-- '같이 하는 사람'이 아니라 '감독하는 사람'이 된다.
-- 끗짱 소개 옆에 "나도 이 책을 읽어요"가 붙으면 그 신호가 생긴다.
--
-- 루틴 대표 사진(cover_url)과 다르다. 대표 사진은 카드 썸네일용 홍보 이미지고,
-- 이건 소개의 일부다. 같은 routine-covers 버킷을 쓴다.

ALTER TABLE routines ADD COLUMN IF NOT EXISTS kkut_book_url text;

COMMENT ON COLUMN routines.kkut_book_url IS
  '끗짱이 이 루틴에서 읽는 책 사진. 소개 옆에 붙는다. 선택 항목';
