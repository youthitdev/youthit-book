-- ════════════════════════════════════════════════════════════════════
-- 한끗독서 마이그레이션 11 ~ 14  (한 번에 실행)
--
--   11  루틴 대표 사진(썸네일)
--   12  적립금(원) → 포인트 + 교환권
--   13  포인트 지급처 넷 (인증 10P · 댓글 1P · 후기 30P · 책인증후기 30P)
--   14  교환권 문턱 250P + 누적 인증 마일스톤 보너스
--
-- 전체를 복사해 Supabase SQL Editor 에 붙여넣고 Run 하세요.
-- 전부 IF NOT EXISTS / CREATE OR REPLACE 라서 두 번 실행해도 안전합니다.
-- 중간에 멈추면 거기서 멈추고 오류 메시지를 알려주세요.
-- ════════════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- migration-11-routine-cover.sql
-- ───────────────────────────────────────────────────────────────
-- 한끗독서 마이그레이션 11
-- 루틴 대표 사진(썸네일)
--
-- 이모지만으로는 루틴이 다 비슷해 보인다. 청소년이 고를 때 눈에 걸리는 건
-- 사진이라, 끗짱이 대표 사진 한 장을 올릴 수 있게 한다. 없으면 이모지로 둔다.
--
-- ⚠️ 이 사진은 끗짱이 고른 홍보용 이미지다. 청소년의 인증 사진이나
--    책 구매 사진과 섞이지 않게 버킷을 따로 둔다.

ALTER TABLE routines ADD COLUMN IF NOT EXISTS cover_url text;

COMMENT ON COLUMN routines.cover_url IS
  '루틴 대표 사진. 끗짱이 올린다. 없으면 화면에서 emoji 로 대체된다';

-- 루틴 카드에 그대로 걸리는 이미지라 공개 버킷
INSERT INTO storage.buckets (id, name, public)
VALUES ('routine-covers', 'routine-covers', true) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "routine_covers_read" ON storage.objects;
CREATE POLICY "routine_covers_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'routine-covers');

-- 자기 폴더(uid)에만 올릴 수 있다
DROP POLICY IF EXISTS "routine_covers_own_insert" ON storage.objects;
CREATE POLICY "routine_covers_own_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'routine-covers'
              AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "routine_covers_own_update" ON storage.objects;
CREATE POLICY "routine_covers_own_update" ON storage.objects FOR UPDATE
  USING (bucket_id = 'routine-covers'
         AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));

DROP POLICY IF EXISTS "routine_covers_own_delete" ON storage.objects;
CREATE POLICY "routine_covers_own_delete" ON storage.objects FOR DELETE
  USING (bucket_id = 'routine-covers'
         AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));


-- ───────────────────────────────────────────────────────────────
-- migration-12-points.sql
-- ───────────────────────────────────────────────────────────────
-- 한끗독서 마이그레이션 12
-- 적립금(원) → 포인트 + 교환권
--
-- 【바뀌는 것】
--   인증 1회 = 20포인트. 300포인트가 모이면 2만원 이하 책 1권 교환권이 나온다.
--   (20p × 15일 = 300p. 기존 1,300원 × 15일 = 19,500원과 같은 값이라 예산은 그대로)
--
-- 【포인트는 계정에 쌓인다 — 중요】
--   루틴이 끝나도 포인트가 사라지지 않는다. 280포인트로 끝나면 다음 루틴에서
--   20포인트만 더 채우면 교환권이 나온다. 하루 빠진 게 전부를 잃는 게 아니라
--   조금 미뤄지는 일이 되도록 하기 위해서다. 고립·은둔 청소년에게
--   '하루 빠지면 끝'은 이탈 방아쇠가 된다.

-- ── 1. 설정
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_cert    int NOT NULL DEFAULT 20;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_voucher int NOT NULL DEFAULT 300;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS voucher_max_amount int NOT NULL DEFAULT 20000;

COMMENT ON COLUMN dokseo_settings.points_per_cert    IS '인증 1회당 포인트. 루틴을 만들 때 이 값이 붙는다';
COMMENT ON COLUMN dokseo_settings.points_per_voucher IS '교환권 1장에 필요한 포인트';
COMMENT ON COLUMN dokseo_settings.voucher_max_amount IS '교환권 1장으로 살 수 있는 책값 상한(원)';
COMMENT ON COLUMN dokseo_settings.amount_per_cert    IS '[미사용] 포인트 전환(migration-12) 이전의 인증 1회당 적립액';

-- ── 2. 루틴
ALTER TABLE routines ADD COLUMN IF NOT EXISTS points_per_cert int NOT NULL DEFAULT 20;
COMMENT ON COLUMN routines.points_per_cert IS '인증 1회당 포인트. 만들 때 설정값이 굳어진다';
COMMENT ON COLUMN routines.amount_per_cert IS '[미사용] 포인트 전환(migration-12) 이전 값';

-- ── 3. 내 포인트 · 교환권
--    본인 것 아니면 못 본다 (예전 dokseo_balance 는 아무 uuid 나 물어볼 수 있었다)
CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_points int; v_per int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  -- 루틴을 가리지 않고 계정 전체로 센다
  SELECT COALESCE(sum(r.points_per_cert), 0) INTO v_points
    FROM certifications c JOIN routines r ON r.id = c.routine_id
   WHERE c.user_id = v_u;

  SELECT points_per_voucher INTO v_per FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 300), 1);

  -- 정산 대기 중인 구매도 교환권을 이미 쓴 것으로 본다 (중복 사용 방지)
  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',      v_points,
    'per_voucher', v_per,
    'earned',      v_earned,
    'used',        v_used,
    'left',        GREATEST(0, v_earned - v_used),
    'to_next',     v_per - (v_points % v_per)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- ── 4. 책 구매는 쓸 수 있는 교환권이 있어야
CREATE OR REPLACE FUNCTION check_book_purchase_insert() RETURNS trigger AS $$
DECLARE v_left int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status       := 'pending';
  NEW.amount       := NULL;
  NEW.receipt_url  := NULL;
  NEW.settled_by   := NULL;
  NEW.settled_at   := NULL;
  NEW.photo_public := false;

  v_left := (dokseo_points(NEW.user_id) ->> 'left')::int;
  IF COALESCE(v_left, 0) <= 0 THEN
    RAISE EXCEPTION '아직 쓸 수 있는 교환권이 없습니다';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 5. 정산 상한은 잔액이 아니라 교환권 한도
CREATE OR REPLACE FUNCTION settle_book_purchase(
  p_purchase_id bigint,
  p_amount      int,
  p_receipt_url text DEFAULT NULL,
  p_note        text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_left int := p_amount; v_take int; v_charge record;
  v_allocs jsonb := '[]'::jsonb; v_pool int;
  v_user uuid; v_routine bigint; v_cap int; v_per int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION '정산 금액이 올바르지 않습니다'; END IF;

  SELECT user_id, routine_id INTO v_user, v_routine
    FROM book_purchases WHERE id = p_purchase_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 대기 상태의 건이 아닙니다 (id=%)', p_purchase_id;
  END IF;

  SELECT voucher_max_amount, points_per_voucher INTO v_cap, v_per
    FROM dokseo_settings WHERE id = 1;
  v_cap := COALESCE(v_cap, 20000);
  v_per := GREATEST(COALESCE(v_per, 300), 1);

  IF p_amount > v_cap THEN
    RAISE EXCEPTION '교환권 한도를 넘습니다 (한도 %원 / 입력 %원)', v_cap, p_amount;
  END IF;

  SELECT COALESCE(sum(remaining_amount), 0) INTO v_pool FROM charges WHERE remaining_amount > 0;
  IF v_pool < p_amount THEN
    RAISE EXCEPTION '도서기금 잔액이 부족합니다 (잔액 %원 / 필요 %원)', v_pool, p_amount;
  END IF;

  FOR v_charge IN
    SELECT id, remaining_amount FROM charges
    WHERE remaining_amount > 0 ORDER BY charged_at, id FOR UPDATE
  LOOP
    EXIT WHEN v_left <= 0;
    v_take := LEAST(v_charge.remaining_amount, v_left);

    INSERT INTO consumption_allocations (purchase_id, charge_id, amount)
    VALUES (p_purchase_id, v_charge.id, v_take);

    UPDATE charges
       SET remaining_amount = remaining_amount - v_take,
           status       = CASE WHEN remaining_amount - v_take = 0 THEN 'completed' ELSE status END,
           completed_at = CASE WHEN remaining_amount - v_take = 0 THEN now() ELSE completed_at END
     WHERE id = v_charge.id;

    v_allocs := v_allocs || jsonb_build_object('charge_id', v_charge.id, 'amount', v_take);
    v_left := v_left - v_take;

    -- 읽은 날 = 그 구매가 뜻하는 일수(교환권 포인트 ÷ 루틴 단가)를, 후원이 댄 몫만큼
    INSERT INTO completion_events (charge_id, students_count, purchases_count, reading_days, total_amount, message)
    SELECT c.id,
           count(DISTINCT p.user_id),
           count(DISTINCT p.id),
           COALESCE(sum( (a.amount::numeric / NULLIF(p.amount, 0))
                         * (v_per::numeric / NULLIF(r.points_per_cert, 0)) ), 0)::int,
           c.book_fund_amount,
           NULL
      FROM charges c
      JOIN consumption_allocations a ON a.charge_id = c.id
      JOIN book_purchases p ON p.id = a.purchase_id
      JOIN routines r ON r.id = p.routine_id
     WHERE c.id = v_charge.id AND c.remaining_amount = 0
     GROUP BY c.id, c.book_fund_amount
    ON CONFLICT (charge_id) DO NOTHING;
  END LOOP;

  UPDATE book_purchases
     SET status = 'settled', amount = p_amount,
         receipt_url = COALESCE(p_receipt_url, receipt_url),
         note = COALESCE(p_note, note),
         settled_by = auth.uid(), settled_at = now()
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('purchase_id', p_purchase_id, 'amount', p_amount, 'allocations', v_allocs);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 6. 루틴을 만들 때 붙는 값도 포인트로
CREATE OR REPLACE FUNCTION check_routine_write() RETURNS trigger AS $$
DECLARE
  v_role   text;
  v_points int;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT points_per_cert INTO v_points FROM dokseo_settings WHERE id = 1;
    NEW.points_per_cert := COALESCE(v_points, 20);
  ELSE
    -- 만들 당시의 단가를 지킨다. 이미 쌓인 포인트가 소급 변동하면 안 된다
    NEW.points_per_cert := OLD.points_per_cert;
  END IF;

  IF is_admin() THEN RETURN NEW; END IF;

  SELECT role INTO v_role FROM profiles WHERE id = auth.uid();
  IF v_role IS DISTINCT FROM 'kkutjjang' THEN
    RAISE EXCEPTION '끗짱만 루틴을 만들 수 있습니다';
  END IF;

  NEW.led_by := auth.uid();
  IF TG_OP = 'INSERT' THEN NEW.status := 'recruit'; END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS routines_check ON routines;
CREATE TRIGGER routines_check BEFORE INSERT OR UPDATE ON routines
  FOR EACH ROW EXECUTE FUNCTION check_routine_write();

-- ── 7. 정리
DROP FUNCTION IF EXISTS dokseo_balance(uuid, bigint);

REVOKE EXECUTE ON FUNCTION dokseo_points(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points(uuid) TO authenticated;


-- ───────────────────────────────────────────────────────────────
-- migration-13-point-sources.sql
-- ───────────────────────────────────────────────────────────────
-- 한끗독서 마이그레이션 13
-- 포인트를 주는 곳을 넷으로
--
--   인증 1회        10P
--   댓글 1개         1P  (하루 5개까지 = 하루 최대 5P)
--   루틴 후기       30P  ← 화면은 아직 없음. 값만 미리 둔다
--   책인증후기      30P  ← 화면은 아직 없음
--
-- 【댓글 포인트 주의】
--   자기 인증에 스스로 단 댓글은 세지 않는다. 안 그러면 혼자서 하루 5P를
--   무한히 만들 수 있다.
--
-- 【문턱 계산】 15일을 하나도 안 빠지고 다 해도
--   인증 150P + 댓글 75P + 루틴 후기 30P = 255P 다.
--   책인증후기(30P)는 책을 받아야 쓸 수 있어 첫 교환권에는 못 쓴다.
--   지금 문턱 300P 로는 완주해도 첫 루틴에서 책을 못 받는다.
--   250P 로 내리려면:  UPDATE dokseo_settings SET points_per_voucher = 250 WHERE id = 1;

UPDATE dokseo_settings SET points_per_cert = 10 WHERE id = 1;
ALTER TABLE routines ALTER COLUMN points_per_cert SET DEFAULT 10;

ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_comment   int NOT NULL DEFAULT 1;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS comment_daily_cap    int NOT NULL DEFAULT 5;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_review    int NOT NULL DEFAULT 30;
ALTER TABLE dokseo_settings ADD COLUMN IF NOT EXISTS points_per_bookreview int NOT NULL DEFAULT 30;

COMMENT ON COLUMN dokseo_settings.points_per_comment    IS '댓글 1개당 포인트';
COMMENT ON COLUMN dokseo_settings.comment_daily_cap     IS '하루에 포인트를 주는 댓글 개수 상한';
COMMENT ON COLUMN dokseo_settings.points_per_review     IS '루틴 후기 1회 포인트 (화면 미구현)';
COMMENT ON COLUMN dokseo_settings.points_per_bookreview IS '책인증후기 1회 포인트 (화면 미구현)';

CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_cert int; v_cmt int; v_per int; v_ppc int; v_cap int;
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap
    INTO v_per, v_ppc, v_cap FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 300), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);

  -- 인증: 루틴을 가리지 않고 계정 전체
  SELECT COALESCE(sum(r.points_per_cert), 0) INTO v_cert
    FROM certifications c JOIN routines r ON r.id = c.routine_id
   WHERE c.user_id = v_u;

  -- 댓글: 하루 상한까지만. 자기 인증에 스스로 단 건 빼고
  SELECT COALESCE(sum(LEAST(n, v_cap)), 0) * v_ppc INTO v_cmt
    FROM (
      SELECT count(*) AS n
        FROM cert_comments m JOIN certifications c ON c.id = m.cert_id
       WHERE m.user_id = v_u AND c.user_id <> v_u
       GROUP BY (m.created_at AT TIME ZONE 'Asia/Seoul')::date
    ) t;

  v_points := v_cert + v_cmt;

  -- 정산 대기 중인 구매도 교환권을 이미 쓴 것으로 본다
  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',      v_points,
    'from_cert',   v_cert,
    'from_comment', v_cmt,
    'per_voucher', v_per,
    'earned',      v_earned,
    'used',        v_used,
    'left',        GREATEST(0, v_earned - v_used),
    'to_next',     v_per - (v_points % v_per)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION dokseo_points(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points(uuid) TO authenticated;


-- ───────────────────────────────────────────────────────────────
-- migration-14-milestones.sql
-- ───────────────────────────────────────────────────────────────
-- 한끗독서 마이그레이션 14
-- 교환권 문턱 250P + 누적 인증 마일스톤 보너스
--
--   누적 10일 / 30일 / 66일 / 100일 / 200일 에 도달하면 각각 +10P.
--   '연속'이 아니라 '누적'이다. 하루 빠져도 잃는 게 없어야 한다 —
--   포인트를 계정에 쌓기로 한 것과 같은 이유다.
--
--   마일스톤은 배열이라 코드를 고치지 않고 늘릴 수 있다:
--     UPDATE dokseo_settings SET bonus_milestones = '{10,30,66,100,200,365}' WHERE id = 1;

UPDATE dokseo_settings SET points_per_voucher = 250 WHERE id = 1;

ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS bonus_milestones    int[] NOT NULL DEFAULT '{10,30,66,100,200}';
ALTER TABLE dokseo_settings
  ADD COLUMN IF NOT EXISTS points_per_milestone int  NOT NULL DEFAULT 10;

COMMENT ON COLUMN dokseo_settings.bonus_milestones     IS '누적 인증 일수 마일스톤. 도달할 때마다 보너스';
COMMENT ON COLUMN dokseo_settings.points_per_milestone IS '마일스톤 하나당 보너스 포인트';

CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int;
  v_per int; v_ppc int; v_cap int; v_pm int; v_ms int[];
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap,
         points_per_milestone, bonus_milestones
    INTO v_per, v_ppc, v_cap, v_pm, v_ms
    FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 250), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);
  v_pm  := COALESCE(v_pm, 10);
  v_ms  := COALESCE(v_ms, '{10,30,66,100,200}');

  -- 인증: 루틴을 가리지 않고 계정 전체
  SELECT count(*), COALESCE(sum(r.points_per_cert), 0) INTO v_n, v_cert
    FROM certifications c JOIN routines r ON r.id = c.routine_id
   WHERE c.user_id = v_u;

  -- 댓글: 하루 상한까지만. 자기 인증에 스스로 단 건 빼고
  SELECT COALESCE(sum(LEAST(n, v_cap)), 0) * v_ppc INTO v_cmt
    FROM (
      SELECT count(*) AS n
        FROM cert_comments m JOIN certifications c ON c.id = m.cert_id
       WHERE m.user_id = v_u AND c.user_id <> v_u
       GROUP BY (m.created_at AT TIME ZONE 'Asia/Seoul')::date
    ) t;

  -- 마일스톤: 지나온 개수만큼
  SELECT COALESCE(count(*), 0) * v_pm INTO v_bonus FROM unnest(v_ms) m WHERE m <= v_n;
  SELECT min(m) INTO v_next FROM unnest(v_ms) m WHERE m > v_n;

  v_points := v_cert + v_cmt + v_bonus;

  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',       v_points,
    'cert_count',   v_n,
    'from_cert',    v_cert,
    'from_comment', v_cmt,
    'from_bonus',   v_bonus,
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

