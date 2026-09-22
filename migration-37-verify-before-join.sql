-- 한끗독서 마이그레이션 37
-- 청소년 확인을 루틴 참여 앞으로 옮긴다
--
-- 처음에는 「책 받을 때」 확인하게 만들었다. 도서기금이 청소년에게 가는지만
-- 보면 된다고 생각했기 때문이다. 그런데 더 큰 걸 놓쳤다.
--
--   루틴은 아이들이 자기 사진과 기록을 서로 보는 자리다.
--   참여하면 같은 루틴 아이들의 사진·이름·기록을 다 볼 수 있다.
--   끗짱은 소속·나이·지원동기를 받고 통화까지 하고 승인하는데,
--   정작 그 방에 들어오는 참여자는 아무 확인 없이 들어왔다.
--
-- 돈 문제이기 전에 안전 문제다. 참여 앞에서 막는다.
--
-- 덤으로 장치가 하나 줄었다. 참여를 못 하면 인증도 포인트도 없으므로
-- 교환권을 따로 막을 필요가 없다. 다만 책 받기 검사는 그대로 남긴다 —
-- 두 겹이어도 손해가 없고, 돈이 나가는 자리다.
--
-- 이미 참여 중인 아이는 건드리지 않는다. INSERT 에만 걸린다.

CREATE OR REPLACE FUNCTION check_participant_insert() RETURNS trigger AS $$
DECLARE v_max int; v_now int; v_status text; v_age int; v_verify text;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  SELECT age_years(birth_date), verify_status
    INTO v_age, v_verify
    FROM profiles WHERE id = NEW.user_id;

  -- 생년월일이 없는 사람(예전 가입자)은 나이로 막지 않는다
  IF v_age IS NOT NULL AND v_age < 14 THEN
    RAISE EXCEPTION '한끗독서는 만 14세부터 함께할 수 있어요';
  END IF;

  IF COALESCE(v_verify, 'none') <> 'approved' THEN
    RAISE EXCEPTION '청소년 확인이 끝나야 루틴에 참여할 수 있어요';
  END IF;

  NEW.status := 'approved';

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

-- 지난번에 빠뜨린 것. 데이터를 읽지 않는 계산 함수라 새어 나갈 건 없지만,
-- 이 저장소는 모든 함수에서 PUBLIC 을 회수해 왔다. 같이 맞춰둔다
REVOKE EXECUTE ON FUNCTION age_years(date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION age_years(date) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ↓ 지금 참여 가능한 사람. 줄이 나와야 성공이다
SELECT u.email, p.name AS 이름, p.role AS 역할,
       p.verify_status AS 확인, age_years(p.birth_date) AS 만나이,
       (p.verify_status = 'approved'
        AND (p.birth_date IS NULL OR age_years(p.birth_date) >= 14)) AS 참여가능
  FROM profiles p JOIN auth.users u ON u.id = p.id ORDER BY p.name;
