-- 한끗독서 마이그레이션 57
-- 루틴에 종류를 둔다 — 「각자 책」과 「함께 읽는 글」
--
-- 【왜】 끗짱 중에 매일 자기가 고른 글을 나누고, 아이들이 그 글을 읽고 소감을
--   남기는 식으로 하고 싶다는 분이 있다. 지금 인증은 책 제목과 쪽수를 꼭
--   받으므로 그 루틴에서는 둘 다 가짜가 된다.
--
-- 【뼈대는 안 바뀐다】 교환권은 「인증한 그 책」을 사는 게 아니라 아무 책이나
--   산다. 그래서 공유 글로 읽어도 끝에는 책이 아이에게 가고, 아이가 책방에
--   간다 — 해법 2·3단계가 그대로다.
--
-- 【기존 루틴은 한 톨도 안 바뀐다】 kind 기본값이 'book' 이라 지금 돌아가는
--   루틴은 전과 똑같이 동작한다.

ALTER TABLE routines
  ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'book';

DO $$ BEGIN
  ALTER TABLE routines ADD CONSTRAINT routines_kind_chk CHECK (kind IN ('book','shared'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

COMMENT ON COLUMN routines.kind IS
  'book = 각자 고른 책을 읽는다 / shared = 끗짱이 올린 글을 다 같이 읽는다';

-- ── 끗짱이 매일 올리는 글 ──────────────────────────────
-- 하루에 한 편. 같은 날 다시 올리면 고쳐 쓰는 것이다
CREATE TABLE IF NOT EXISTS routine_posts (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  routine_id bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  user_id    uuid   NOT NULL REFERENCES auth.users  ON DELETE CASCADE,
  day        date   NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Seoul')::date),
  title      text,
  body       text   NOT NULL CHECK (btrim(body) <> ''),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (routine_id, day)
);
CREATE INDEX IF NOT EXISTS routine_posts_idx ON routine_posts (routine_id, day DESC);

COMMENT ON TABLE routine_posts IS '「함께 읽는 글」 루틴에서 끗짱이 매일 올리는 글';

ALTER TABLE routine_posts ENABLE ROW LEVEL SECURITY;

-- 읽기는 인증과 같은 범위 — 그 루틴에 있는 사람과 운영진
DROP POLICY IF EXISTS posts_read ON routine_posts;
CREATE POLICY posts_read ON routine_posts FOR SELECT TO authenticated
  USING (is_admin() OR routine_id IN (SELECT visible_routine_ids()));

-- 쓰기는 그 루틴의 끗짱만. 남의 루틴에 글을 꽂을 수 없다
DROP POLICY IF EXISTS posts_write ON routine_posts;
CREATE POLICY posts_write ON routine_posts FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid()
    AND EXISTS (SELECT 1 FROM routines r WHERE r.id = routine_id AND r.led_by = auth.uid()));

DROP POLICY IF EXISTS posts_edit ON routine_posts;
CREATE POLICY posts_edit ON routine_posts FOR UPDATE TO authenticated
  USING (is_admin() OR EXISTS (SELECT 1 FROM routines r WHERE r.id = routine_id AND r.led_by = auth.uid()))
  WITH CHECK (is_admin() OR EXISTS (SELECT 1 FROM routines r WHERE r.id = routine_id AND r.led_by = auth.uid()));

DROP POLICY IF EXISTS posts_del ON routine_posts;
CREATE POLICY posts_del ON routine_posts FOR DELETE TO authenticated
  USING (is_admin() OR EXISTS (SELECT 1 FROM routines r WHERE r.id = routine_id AND r.led_by = auth.uid()));

-- ── 종류는 만든 뒤 못 바꾼다 ───────────────────────────
-- 중간에 바꾸면 이미 쌓인 인증이 붕 뜬다 (쪽수가 있는데 쪽수를 안 받는 루틴이 된다)
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
    NEW.kind         := OLD.kind;      -- 만든 뒤에는 종류를 못 바꾼다
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'routines' AND column_name = 'kind')            AS 종류칸,
       (SELECT count(*) FROM information_schema.tables
         WHERE table_name = 'routine_posts')                                AS 글표,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'routine_posts') AS 정책수,
       (SELECT count(*) FROM routines WHERE kind = 'book')                  AS 기존루틴_각자책;
