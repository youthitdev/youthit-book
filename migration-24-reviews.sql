-- 한끗독서 마이그레이션 24
-- 후기 — 루틴 후기 30P, 책인증후기 30P
--
-- 【배경】 migration-13 에서 값만 정해두고 화면을 안 만들었다.
--   그래서 250P 를 채우는 길이 사실상 인증 10P 뿐이었다.
--   15일을 하나도 안 빠지고 다 해도
--     인증 150P + 댓글 75P + 마일스톤(10일) 10P = 235P → 교환권 없음.
--   루틴 후기 30P 가 붙어야 265P 로 첫 책을 받는다. 그래서 후기가 있어야 한다.
--
-- 【언제 쓸 수 있나】
--   루틴 후기   — 루틴이 끝난 뒤 (end_date 가 지났거나 status='done'). 루틴당 1번
--   책인증후기  — 책을 받은 기록(book_purchases)마다 1번
--
-- 【20자 이상만 받는다】 한 문장은 되어야 30P 값을 한다.
--   그 이상 요구하지 않는다 — 글자 수 벽은 쓰기 어려운 아이를 먼저 막는다.

-- ────────────────────────────────────────────────────────────────────
-- 1. 표
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS reviews (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id     uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  kind        text   NOT NULL CHECK (kind IN ('routine','book')),
  -- 열람 범위를 인증과 똑같이 맞추려고 두 종류 모두 routine_id 를 갖는다
  routine_id  bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  purchase_id bigint REFERENCES book_purchases(id) ON DELETE CASCADE,
  book_title  text,
  content     text   NOT NULL,
  -- 후원자 화면에 내보낼 건 운영진이 고른 것만 (문장 고르기와 같은 방식)
  is_public   boolean NOT NULL DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE reviews IS '루틴 후기 / 책인증후기. 각 30P';

-- 루틴당 한 번, 책 한 권당 한 번
CREATE UNIQUE INDEX IF NOT EXISTS reviews_one_per_routine
  ON reviews (user_id, routine_id) WHERE kind = 'routine';
CREATE UNIQUE INDEX IF NOT EXISTS reviews_one_per_purchase
  ON reviews (purchase_id) WHERE kind = 'book';

CREATE INDEX IF NOT EXISTS reviews_routine_idx ON reviews (routine_id, created_at DESC);
CREATE INDEX IF NOT EXISTS reviews_user_idx    ON reviews (user_id);

-- ────────────────────────────────────────────────────────────────────
-- 2. 쓸 수 있는지 서버가 판단한다
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION check_review_write() RETURNS trigger AS $$
DECLARE
  v_end    date;
  v_status text;
  v_owner  uuid;
  v_rt     bigint;
BEGIN
  IF is_admin() OR auth.uid() IS NULL THEN
    NEW.updated_at := now();
    RETURN NEW;
  END IF;

  NEW.user_id := auth.uid();
  -- 공개 여부는 운영진만 바꾼다.
  -- (INSERT 트리거에서 OLD 를 읽으면 'record old is not assigned yet' 오류가 난다)
  IF TG_OP = 'INSERT' THEN NEW.is_public := false;
  ELSE                     NEW.is_public := OLD.is_public;
  END IF;
  NEW.updated_at := now();

  IF length(btrim(COALESCE(NEW.content, ''))) < 20 THEN
    RAISE EXCEPTION '후기를 스무 자 이상 적어주세요';
  END IF;

  IF NEW.kind = 'routine' THEN
    NEW.purchase_id := NULL;

    IF NOT EXISTS (SELECT 1 FROM routine_participants
                    WHERE routine_id = NEW.routine_id
                      AND user_id = auth.uid() AND status = 'approved') THEN
      RAISE EXCEPTION '참여한 루틴에만 후기를 쓸 수 있습니다';
    END IF;

    SELECT end_date, status INTO v_end, v_status FROM routines WHERE id = NEW.routine_id;
    IF NOT (v_status = 'done'
            OR (v_end IS NOT NULL AND v_end < (now() AT TIME ZONE 'Asia/Seoul')::date)) THEN
      RAISE EXCEPTION '루틴이 끝나면 후기를 쓸 수 있어요';
    END IF;

  ELSE  -- book
    IF NEW.purchase_id IS NULL THEN
      RAISE EXCEPTION '어떤 책인지 알 수 없습니다';
    END IF;
    SELECT user_id, routine_id INTO v_owner, v_rt
      FROM book_purchases WHERE id = NEW.purchase_id;
    IF v_owner IS DISTINCT FROM auth.uid() THEN
      RAISE EXCEPTION '내가 받은 책에만 후기를 쓸 수 있습니다';
    END IF;
    NEW.routine_id := v_rt;   -- 열람 범위를 그 루틴에 맞춘다
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS reviews_check ON reviews;
CREATE TRIGGER reviews_check BEFORE INSERT OR UPDATE ON reviews
  FOR EACH ROW EXECUTE FUNCTION check_review_write();

-- ────────────────────────────────────────────────────────────────────
-- 3. RLS — 인증 기록과 같은 범위
-- ────────────────────────────────────────────────────────────────────
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS reviews_read ON reviews;
CREATE POLICY reviews_read ON reviews FOR SELECT TO authenticated
  USING (
    user_id = auth.uid()
    OR is_admin()
    OR routine_id IN (SELECT visible_routine_ids())
  );

DROP POLICY IF EXISTS reviews_own_insert ON reviews;
CREATE POLICY reviews_own_insert ON reviews FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS reviews_own_update ON reviews;
CREATE POLICY reviews_own_update ON reviews FOR UPDATE TO authenticated
  USING      (user_id = auth.uid() OR is_admin())
  WITH CHECK (user_id = auth.uid() OR is_admin());

DROP POLICY IF EXISTS reviews_own_delete ON reviews;
CREATE POLICY reviews_own_delete ON reviews FOR DELETE TO authenticated
  USING (user_id = auth.uid() OR is_admin());

-- ────────────────────────────────────────────────────────────────────
-- 4. 포인트에 후기를 더한다
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int; v_rev int;
  v_per int; v_ppc int; v_cap int; v_pm int; v_ms int[]; v_pr int; v_pb int;
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap,
         points_per_milestone, bonus_milestones,
         points_per_review, points_per_bookreview
    INTO v_per, v_ppc, v_cap, v_pm, v_ms, v_pr, v_pb
    FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 250), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);
  v_pm  := COALESCE(v_pm, 10);
  v_ms  := COALESCE(v_ms, '{10,30,66,100,200}');
  v_pr  := COALESCE(v_pr, 30);
  v_pb  := COALESCE(v_pb, 30);

  SELECT count(*), COALESCE(sum(r.points_per_cert), 0) INTO v_n, v_cert
    FROM certifications c JOIN routines r ON r.id = c.routine_id
   WHERE c.user_id = v_u;

  SELECT COALESCE(sum(LEAST(n, v_cap)), 0) * v_ppc INTO v_cmt
    FROM (
      SELECT count(*) AS n
        FROM cert_comments m JOIN certifications c ON c.id = m.cert_id
       WHERE m.user_id = v_u AND c.user_id <> v_u
       GROUP BY (m.created_at AT TIME ZONE 'Asia/Seoul')::date
    ) t;

  SELECT COALESCE(count(*), 0) * v_pm INTO v_bonus FROM unnest(v_ms) m WHERE m <= v_n;
  SELECT min(m) INTO v_next FROM unnest(v_ms) m WHERE m > v_n;

  -- 후기
  SELECT COALESCE(count(*) FILTER (WHERE kind = 'routine'), 0) * v_pr
       + COALESCE(count(*) FILTER (WHERE kind = 'book'),    0) * v_pb
    INTO v_rev FROM reviews WHERE user_id = v_u;

  v_points := v_cert + v_cmt + v_bonus + v_rev;

  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',       v_points,
    'cert_count',   v_n,
    'from_cert',    v_cert,
    'from_comment', v_cmt,
    'from_bonus',   v_bonus,
    'from_review',  v_rev,
    'next_milestone', v_next,
    'per_voucher',  v_per,
    'earned',       v_earned,
    'used',         v_used,
    'left',         GREATEST(0, v_earned - v_used),
    'to_next',      v_per - (v_points % v_per)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION dokseo_points(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points(uuid) TO authenticated;

-- ────────────────────────────────────────────────────────────────────
-- 5. 후원자 화면에 내보낼 후기 (운영진이 고른 것만, 이름 없이)
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION dokseo_public_reviews(p_limit int DEFAULT 6)
RETURNS TABLE (kind text, book_title text, content text, created_at timestamptz) AS $$
  SELECT kind, book_title, content, created_at
    FROM reviews
   WHERE is_public
   ORDER BY created_at DESC
   LIMIT GREATEST(COALESCE(p_limit, 6), 1);
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_public_reviews(int) TO anon, authenticated;
