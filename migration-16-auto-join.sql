-- 한끗독서 마이그레이션 16
-- 끗짱 승인 없이 바로 참여
--
-- 참여 청소년은 이미 자격 확인을 거쳐 들어온다. 앱에서 한 번 더 승인을
-- 기다리게 할 이유가 없다. 신청하면 곧바로 참여 상태가 된다.
--
-- 【대신 정원은 서버가 막는다】
--   지금까지는 끗짱 승인이 사실상 정원 문지기였다. 승인을 없애면
--   정원 8명짜리에 9명이 들어갈 수 있으므로 여기서 막는다.

ALTER TABLE routine_participants ALTER COLUMN status SET DEFAULT 'approved';

CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status := 'approved';   -- 승인 절차 없음

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

-- 이미 승인을 기다리던 신청은 전부 참여로 올린다
UPDATE routine_participants SET status = 'approved' WHERE status = 'pending';
