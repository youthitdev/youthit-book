-- 한끗독서 마이그레이션 15
-- 신청할 때 '내가 읽을 책' 사진
--
-- 아이들이 읽을 책을 찍어서 시작한다. 신청 단계에서 한 장 받아두면
--   ① 끗짱이 승인할 때 "이 친구는 무슨 책으로 시작하는구나"를 본다
--   ② 아이도 무엇을 읽을지 정하고 들어오게 된다
--
-- 필수가 아니다. 지금 손에 책이 없는 아이를 신청 단계에서 막지 않는다.
-- (교환권은 250P 를 모아야 나오므로, 처음에는 집·도서관 책으로 시작한다)

ALTER TABLE routine_participants ADD COLUMN IF NOT EXISTS book_photo_url text;

COMMENT ON COLUMN routine_participants.book_photo_url IS
  '신청할 때 올린 "내가 읽을 책" 사진. 선택 항목';
