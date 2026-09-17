-- 한끗독서 마이그레이션 17b
-- migration-17 의 ALTER TABLE 이 실제로는 적용되지 않았다.
--
-- 왜 모르고 지나갔나:
--   PostgreSQL 은 plpgsql 함수를 만들 때 컬럼 이름을 검사하지 않는다.
--   그래서 NEW.book_title 을 쓰는 함수는 컬럼이 없어도 잘 만들어지고,
--   에디터는 Success 를 띄운다. 터지는 건 아이가 루틴에 참여하는 순간이다.
--
-- 그래서 이 파일은 마지막에 결과를 "보여준다".
--   Success. No rows returned  ← 이게 뜨면 실패한 것이다.
--   표에 book_title 한 줄이 나와야 성공이다.

ALTER TABLE routine_participants ADD COLUMN IF NOT EXISTS book_title text;

COMMENT ON COLUMN routine_participants.book_title IS '참여할 때 적은 "내가 읽을 책" 제목';

-- 함수와 트리거도 같이 다시 만든다 (있어도 안전하다)
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

NOTIFY pgrst, 'reload schema';   -- PostgREST 스키마 캐시 새로고침

-- ↓ 여기서 한 줄이 나와야 한다
SELECT column_name AS "생긴 컬럼", data_type AS "자료형"
  FROM information_schema.columns
 WHERE table_name = 'routine_participants'
   AND column_name = 'book_title';
