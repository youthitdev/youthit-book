-- 한끗독서 마이그레이션 17
-- 참여할 때 책 사진 · 책 제목 · 참여 각오를 모두 받는다
--
-- 승인 절차를 없앤 대신, 무엇을 읽을지 정하고 들어오게 한다.

ALTER TABLE routine_participants ADD COLUMN IF NOT EXISTS book_title text;

COMMENT ON COLUMN routine_participants.book_title IS '참여할 때 적은 "내가 읽을 책" 제목';

CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status := 'approved';   -- 승인 절차 없음

  IF COALESCE(NEW.book_photo_url, '') = '' THEN
    RAISE EXCEPTION '읽을 책 사진을 올려주세요';
  END IF;
  IF COALESCE(btrim(NEW.book_title), '') = '' THEN
    RAISE EXCEPTION '읽을 책 제목을 적어주세요';
  END IF;
  IF COALESCE(btrim(NEW.note), '') = '' THEN
    RAISE EXCEPTION '참여 각오를 적어주세요';
  END IF;

  SELECT max_people, status INTO v_max, v_status FROM routines WHERE id = NEW.routine_id;
  IF v_status = 'done' THEN
    RAISE EXCEPTION '이미 끝난 루틴입니다';
  END IF;

  SELECT count(*) INTO v_now FROM routine_participants
   WHERE routine_id = NEW.routine_id AND status = 'approved';
  IF v_now >= COALESCE(v_max, 0) THEN
    RAISE EXCEPTION '모집 인원이 찼습니다';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS participants_check ON routine_participants;
CREATE TRIGGER participants_check BEFORE INSERT ON routine_participants
  FOR EACH ROW EXECUTE FUNCTION check_participant_insert();
