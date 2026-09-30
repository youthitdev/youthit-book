-- 한끗독서 마이그레이션 58
-- 오프라인 공유회가 있는 루틴
--
-- 어떤 루틴은 마지막에 다 같이 모여 이야기를 나누는 게 핵심이다.
-- 그런 루틴은 **공유회에 와야 책을 받는다** — 읽기만 하고 안 오면 반쪽이다.
--
-- 【참석은 끗짱이 표시한다】 그 자리에 있는 사람만 누가 왔는지 안다.
--   운영진은 모임에 없다. 끗짱은 이미 승인받은 어른이고, 자기 루틴의
--   참여자만 손댈 수 있다 (parts_leader_update).
--
-- 【조건은 나중에 못 붙인다】 아이가 들어온 뒤에 「사실 공유회도 와야 해」가
--   되면 안 된다. 켜는 건 만들 때만, 끄는 건 언제든 (모임이 취소될 수 있다).

ALTER TABLE routines
  ADD COLUMN IF NOT EXISTS meetup_required boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS meetup_at       timestamptz,
  ADD COLUMN IF NOT EXISTS meetup_place    text,
  ADD COLUMN IF NOT EXISTS meetup_note     text;

COMMENT ON COLUMN routines.meetup_required IS '오프라인 공유회에 와야 교환권을 쓸 수 있다';
COMMENT ON COLUMN routines.meetup_at       IS '공유회 날짜·시각';
COMMENT ON COLUMN routines.meetup_place    IS '공유회 장소';
COMMENT ON COLUMN routines.meetup_note     IS '준비물·찾아오는 길 같은 안내';

ALTER TABLE routine_participants
  ADD COLUMN IF NOT EXISTS met_at timestamptz;
COMMENT ON COLUMN routine_participants.met_at IS '공유회에 온 것을 끗짱이 표시한 시각';

-- ── 공유회에 와야 책을 받는다 ──────────────────────────
CREATE OR REPLACE FUNCTION check_purchase_verified() RETURNS trigger AS $$
DECLARE v text; v_role text; v_meet boolean; v_met timestamptz;
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;

  SELECT verify_status, role INTO v, v_role FROM profiles WHERE id = NEW.user_id;
  IF COALESCE(v_role, 'youth') <> 'youth' THEN
    RAISE EXCEPTION '도서기금은 청소년에게 쓰는 돈이에요';
  END IF;
  IF COALESCE(v, 'none') <> 'approved' THEN
    RAISE EXCEPTION '청소년 확인이 끝나야 책을 받을 수 있어요';
  END IF;

  SELECT r.meetup_required INTO v_meet FROM routines r WHERE r.id = NEW.routine_id;
  IF COALESCE(v_meet, false) THEN
    SELECT p.met_at INTO v_met FROM routine_participants p
     WHERE p.routine_id = NEW.routine_id AND p.user_id = NEW.user_id;
    IF v_met IS NULL THEN
      RAISE EXCEPTION '공유회에 참석해야 책을 받을 수 있어요';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 조건을 나중에 붙이지 못하게 ────────────────────────
CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
BEGIN
  IF auth.uid() IS NULL OR is_admin() THEN RETURN NEW; END IF;

  IF NOT is_approved_kkut() THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.led_by := auth.uid();
    NEW.status := 'pending';
    NEW.sponsor_name := NULL;
  ELSE
    IF OLD.status = 'pending' AND NEW.status <> 'pending' THEN NEW.status := 'pending'; END IF;
    IF OLD.status <> 'pending' AND NEW.status = 'pending' THEN NEW.status := OLD.status; END IF;
    IF OLD.status = 'pending' THEN NEW.reject_reason := NULL; END IF;
    NEW.led_by       := OLD.led_by;
    NEW.sponsor_name := OLD.sponsor_name;
    NEW.kind         := OLD.kind;
    -- 공유회 조건은 켜는 건 만들 때만. 끄는 건 언제든 (모임이 취소될 수 있다)
    IF NOT OLD.meetup_required THEN NEW.meetup_required := false; END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'routines' AND column_name LIKE 'meetup%')        AS 루틴칸,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'routine_participants' AND column_name = 'met_at') AS 참석칸,
       (SELECT count(*) FROM routines WHERE meetup_required)                   AS 공유회루틴,
       (SELECT count(*) FROM routines)                                         AS 전체루틴;
