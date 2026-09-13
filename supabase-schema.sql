-- ════════════════════════════════════════════════════════════════════
-- 한끗독서 — 청소년 독서 후원 레이어 스키마
-- ════════════════════════════════════════════════════════════════════
--
-- 【전제】 한끗루틴과 "같은" Supabase 프로젝트에 추가하는 스키마입니다.
--   15일 연속 인증 판별을 위해 profiles / routines / certifications 를
--   그대로 조회해야 하므로 별도 프로젝트로 분리하면 조인이 불가능합니다.
--   → 실행 전 반드시 백업하고, 스테이징에서 먼저 돌려보세요.
--
-- 【핵심 규칙】
--   1. 후원금은 입금 즉시 80% 도서기금 / 20% 운영비로 분리 (비율은 dokseo_settings)
--   2. 차감은 FIFO — 가장 오래된 후원 건부터 소진
--   3. "책 받음(정산 대기)" 과 "정산 완료(영수증 금액 확정)" 는 분리된 상태
--   4. 청소년 개인 식별 정보는 후원자에게 절대 노출되지 않음 (RLS로 강제)
-- ════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────
-- 0. 관리자 판별 — 한끗루틴 스키마에 이미 있으면 이 블록은 건너뛰어도 됩니다
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean AS $$
  SELECT auth.email() IN ('dev@youthvoice.or.kr', 'yv@youthvoice.or.kr');
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ────────────────────────────────────────────────────────────────────
-- 1. 설정 — 후원금 분리 비율
--    기부금품법상 운영비 비율 상한 확인 결과에 따라 바뀔 수 있어 테이블로 둠
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dokseo_settings (
  id                 int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  book_fund_rate     numeric(4,3) NOT NULL DEFAULT 0.800 CHECK (book_fund_rate > 0 AND book_fund_rate <= 1),
  book_price_cap     int NOT NULL DEFAULT 20000,   -- 1인당 도서 지급 상한
  milestone_amount   int NOT NULL DEFAULT 100000,  -- "10만원 = 루틴 1개" 마일스톤 (해석 A)
  updated_at         timestamptz DEFAULT now()
);
INSERT INTO dokseo_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;


-- ────────────────────────────────────────────────────────────────────
-- 2. 후원자
--    도너스를 통해 들어온 후원자는 우리 앱 계정이 없을 수 있으므로
--    user_id 는 nullable, email 을 동기화 매칭 키로 사용
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sponsors (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid UNIQUE REFERENCES auth.users ON DELETE SET NULL,
  email        text UNIQUE NOT NULL,
  nickname     text NOT NULL,
  show_in_list boolean NOT NULL DEFAULT true,  -- "함께하는 후원자" 목록 노출 동의
  created_at   timestamptz DEFAULT now()
);


-- ────────────────────────────────────────────────────────────────────
-- 3. 후원 내역
--    도너스 연동 방식(API/웹훅 vs CSV) 확정 전까지는 source='manual' 로 수기 입력
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS charges (
  id                   bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  sponsor_id           uuid NOT NULL REFERENCES sponsors(id) ON DELETE RESTRICT,
  amount               int  NOT NULL CHECK (amount > 0),
  book_fund_amount     int  NOT NULL CHECK (book_fund_amount >= 0),
  operation_fee_amount int  NOT NULL CHECK (operation_fee_amount >= 0),
  remaining_amount     int  NOT NULL CHECK (remaining_amount >= 0),
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed')),
  source               text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','donus')),
  external_ref         text,                      -- 도너스 거래번호
  charged_at           timestamptz NOT NULL DEFAULT now(),  -- FIFO 정렬 기준
  completed_at         timestamptz,
  created_at           timestamptz DEFAULT now(),
  CONSTRAINT charges_split_sums CHECK (book_fund_amount + operation_fee_amount = amount),
  CONSTRAINT charges_remaining_le_fund CHECK (remaining_amount <= book_fund_amount)
);
CREATE INDEX IF NOT EXISTS charges_fifo_idx ON charges (charged_at, id) WHERE remaining_amount > 0;
CREATE INDEX IF NOT EXISTS charges_sponsor_idx ON charges (sponsor_id, charged_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS charges_external_ref_idx ON charges (external_ref) WHERE external_ref IS NOT NULL;

-- 후원 입력 시 80/20 자동 분리 (금액은 원 단위 내림, 잔돈은 도서기금 쪽으로)
CREATE OR REPLACE FUNCTION split_charge_amounts() RETURNS trigger AS $$
DECLARE
  v_rate numeric;
  v_op   int;
BEGIN
  SELECT book_fund_rate INTO v_rate FROM dokseo_settings WHERE id = 1;
  v_op := floor(NEW.amount * (1 - v_rate));
  NEW.operation_fee_amount := v_op;
  NEW.book_fund_amount     := NEW.amount - v_op;
  NEW.remaining_amount     := NEW.amount - v_op;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS charges_split ON charges;
CREATE TRIGGER charges_split BEFORE INSERT ON charges
  FOR EACH ROW EXECUTE FUNCTION split_charge_amounts();


-- ────────────────────────────────────────────────────────────────────
-- 4. 책 선물 지급 건 — 정산의 단위
--    15일 연속 인증을 채운 청소년이 독립서점에서 책을 받고,
--    책으로 얼굴을 가린 사진을 올리면 여기에 'pending' 으로 생성됨
--    ⚠️ 개인 식별 정보(청소년 user_id, 사진)를 담으므로 후원자는 조회 불가
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS book_gifts (
  id              bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id         uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  routine_id      bigint REFERENCES routines(id) ON DELETE SET NULL,
  bookstore_name  text,
  proof_photo_url text,                                  -- 책+얼굴가림 사진 (내부 확인용)
  proof_cert_id   bigint REFERENCES certifications(id) ON DELETE SET NULL,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','settled','void')),
  gift_amount     int CHECK (gift_amount IS NULL OR gift_amount > 0),  -- 영수증 기준 실제 금액
  receipt_url     text,
  note            text,
  settled_by      uuid REFERENCES auth.users ON DELETE SET NULL,
  settled_at      timestamptz,
  created_at      timestamptz DEFAULT now(),
  CONSTRAINT book_gifts_settled_needs_amount
    CHECK (status <> 'settled' OR (gift_amount IS NOT NULL AND settled_at IS NOT NULL))
);
-- 한 루틴당 1인 1회 지급
CREATE UNIQUE INDEX IF NOT EXISTS book_gifts_once_idx
  ON book_gifts (user_id, routine_id) WHERE status <> 'void';
CREATE INDEX IF NOT EXISTS book_gifts_status_idx ON book_gifts (status, created_at);


-- 4-1. 한끗루틴의 어떤 루틴이 한끗독서 루틴인지 표시
--      (체크된 루틴에서만 청소년에게 "책 받았어요" 기록 화면이 열림)
ALTER TABLE routines ADD COLUMN IF NOT EXISTS dokseo boolean NOT NULL DEFAULT false;

-- 4-1-b. 독서루틴 인증에 딸리는 기록 — 필사 문장과 진도
--   quote      : 오늘 읽은 곳에서 옮겨 적은 문장 (필사). 독서루틴 인증의 필수 항목
--   book_title : 지금 읽는 책. 다음 인증에서 자동으로 채워짐
--   page_end   : 오늘까지 읽은 페이지. 전날보다 줄면 앱이 부드럽게 물어보되 막지는 않음
ALTER TABLE certifications ADD COLUMN IF NOT EXISTS quote      text;
ALTER TABLE certifications ADD COLUMN IF NOT EXISTS book_title text;
ALTER TABLE certifications ADD COLUMN IF NOT EXISTS page_end   int;

-- 4-2. 청소년이 직접 올리는 "책 받았어요" 기록의 자격·값 검증
--      자격: 그 루틴의 전체 일수만큼 인증을 채웠을 것 (15일 루틴이면 15일 전부)
--      청소년이 올린 행은 금액·정산 관련 값을 절대 담을 수 없게 강제로 비움
CREATE OR REPLACE FUNCTION check_book_gift_insert() RETURNS trigger AS $$
DECLARE
  v_dokseo boolean;
  v_days   int;
  v_certs  int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status      := 'pending';
  NEW.gift_amount := NULL;
  NEW.receipt_url := NULL;
  NEW.settled_by  := NULL;
  NEW.settled_at  := NULL;

  SELECT dokseo, (end_date - start_date) + 1
    INTO v_dokseo, v_days
    FROM routines WHERE id = NEW.routine_id;

  IF NOT COALESCE(v_dokseo, false) THEN
    RAISE EXCEPTION '한끗독서 루틴이 아닙니다';
  END IF;

  SELECT count(*) INTO v_certs
    FROM certifications
   WHERE routine_id = NEW.routine_id AND user_id = NEW.user_id;

  IF v_certs < COALESCE(v_days, 15) THEN
    RAISE EXCEPTION '인증 일수가 부족합니다 (%일 / %일)', v_certs, COALESCE(v_days, 15);
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS book_gifts_check ON book_gifts;
CREATE TRIGGER book_gifts_check BEFORE INSERT ON book_gifts
  FOR EACH ROW EXECUTE FUNCTION check_book_gift_insert();


-- ────────────────────────────────────────────────────────────────────
-- 5. FIFO 차감 매핑 — 어느 후원 건에서 얼마가 빠져나갔는지
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS consumption_allocations (
  id            bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  book_gift_id  bigint NOT NULL REFERENCES book_gifts(id) ON DELETE RESTRICT,
  charge_id     bigint NOT NULL REFERENCES charges(id)    ON DELETE RESTRICT,
  amount        int    NOT NULL CHECK (amount > 0),
  created_at    timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS alloc_charge_idx ON consumption_allocations (charge_id);
CREATE INDEX IF NOT EXISTS alloc_gift_idx   ON consumption_allocations (book_gift_id);


-- ────────────────────────────────────────────────────────────────────
-- 6. 후원 소진 완료 이벤트 — 후원자 대시보드의 "완료 카드"
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS completion_events (
  id             bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  charge_id      bigint NOT NULL UNIQUE REFERENCES charges(id) ON DELETE CASCADE,
  students_count int NOT NULL,
  gifts_count    int NOT NULL,
  total_amount   int NOT NULL,
  message        text,
  created_at     timestamptz DEFAULT now()
);


-- ════════════════════════════════════════════════════════════════════
-- 7. 정산 함수 — 관리자가 영수증 금액을 입력하면 FIFO로 차감
--    금액 확정과 차감이 한 트랜잭션에서 원자적으로 처리됨
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION settle_book_gift(
  p_gift_id     bigint,
  p_amount      int,
  p_receipt_url text DEFAULT NULL,
  p_note        text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_cap        int;
  v_left       int := p_amount;
  v_take       int;
  v_charge     record;
  v_allocs     jsonb := '[]'::jsonb;
  v_pool       int;
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION '정산 권한이 없습니다';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION '정산 금액이 올바르지 않습니다';
  END IF;

  SELECT book_price_cap INTO v_cap FROM dokseo_settings WHERE id = 1;
  IF p_amount > v_cap THEN
    RAISE EXCEPTION '1인당 도서 지급 상한(%원)을 넘습니다', v_cap;
  END IF;

  -- 대상 건 잠금 + 상태 확인
  PERFORM 1 FROM book_gifts WHERE id = p_gift_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 대기 상태의 건이 아닙니다 (id=%)', p_gift_id;
  END IF;

  SELECT COALESCE(sum(remaining_amount), 0) INTO v_pool FROM charges WHERE remaining_amount > 0;
  IF v_pool < p_amount THEN
    RAISE EXCEPTION '도서기금 잔액이 부족합니다 (잔액 %원 / 필요 %원)', v_pool, p_amount;
  END IF;

  -- FIFO: 가장 오래된 후원 건부터 차감
  FOR v_charge IN
    SELECT id, remaining_amount FROM charges
    WHERE remaining_amount > 0
    ORDER BY charged_at, id
    FOR UPDATE
  LOOP
    EXIT WHEN v_left <= 0;
    v_take := LEAST(v_charge.remaining_amount, v_left);

    INSERT INTO consumption_allocations (book_gift_id, charge_id, amount)
    VALUES (p_gift_id, v_charge.id, v_take);

    UPDATE charges
       SET remaining_amount = remaining_amount - v_take,
           status       = CASE WHEN remaining_amount - v_take = 0 THEN 'completed' ELSE status END,
           completed_at = CASE WHEN remaining_amount - v_take = 0 THEN now() ELSE completed_at END
     WHERE id = v_charge.id;

    v_allocs := v_allocs || jsonb_build_object('charge_id', v_charge.id, 'amount', v_take);
    v_left := v_left - v_take;

    -- 소진 완료된 후원 건은 완료 카드 생성
    INSERT INTO completion_events (charge_id, students_count, gifts_count, total_amount, message)
    SELECT c.id,
           count(DISTINCT g.user_id),
           count(DISTINCT g.id),
           c.book_fund_amount,
           NULL
      FROM charges c
      JOIN consumption_allocations a ON a.charge_id = c.id
      JOIN book_gifts g ON g.id = a.book_gift_id
     WHERE c.id = v_charge.id AND c.remaining_amount = 0
     GROUP BY c.id, c.book_fund_amount
    ON CONFLICT (charge_id) DO NOTHING;
  END LOOP;

  UPDATE book_gifts
     SET status      = 'settled',
         gift_amount = p_amount,
         receipt_url = COALESCE(p_receipt_url, receipt_url),
         note        = COALESCE(p_note, note),
         settled_by  = auth.uid(),
         settled_at  = now()
   WHERE id = p_gift_id;

  RETURN jsonb_build_object('gift_id', p_gift_id, 'amount', p_amount, 'allocations', v_allocs);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ════════════════════════════════════════════════════════════════════
-- 8. 공개 집계 — 후원자 대시보드용
--    개별 청소년을 식별할 수 없는 형태로만 반환 (SECURITY DEFINER)
-- ════════════════════════════════════════════════════════════════════

-- 8-1. 도서기금 풀 현황
CREATE OR REPLACE FUNCTION dokseo_pool_status() RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'total_donated',   COALESCE((SELECT sum(amount) FROM charges), 0),
    'book_fund',       COALESCE((SELECT sum(book_fund_amount) FROM charges), 0),
    'operation_fee',   COALESCE((SELECT sum(operation_fee_amount) FROM charges), 0),
    'remaining',       COALESCE((SELECT sum(remaining_amount) FROM charges), 0),
    'spent',           COALESCE((SELECT sum(amount) FROM consumption_allocations), 0),
    'books_delivered', COALESCE((SELECT count(*) FROM book_gifts WHERE status = 'settled'), 0),
    'books_pending',   COALESCE((SELECT count(*) FROM book_gifts WHERE status = 'pending'), 0),
    'students_reached',COALESCE((SELECT count(DISTINCT user_id) FROM book_gifts WHERE status <> 'void'), 0),
    'sponsors_count',  COALESCE((SELECT count(DISTINCT sponsor_id) FROM charges), 0)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 8-2. 익명 인증 피드 — 날짜별 인증 수·인원 수만 (누가 했는지는 반환하지 않음)
CREATE OR REPLACE FUNCTION dokseo_activity_feed(p_days int DEFAULT 14)
RETURNS TABLE (day date, cert_count bigint, student_count bigint) AS $$
  SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date AS day,
         count(*)                  AS cert_count,
         count(DISTINCT user_id)   AS student_count
    FROM certifications
   WHERE created_at >= now() - make_interval(days => p_days)
   GROUP BY 1
   ORDER BY 1 DESC;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 8-3. 함께하는 후원자 — 노출 동의한 사람의 닉네임만
CREATE OR REPLACE FUNCTION dokseo_sponsor_wall(p_limit int DEFAULT 50)
RETURNS TABLE (nickname text, joined_at timestamptz) AS $$
  SELECT s.nickname, min(c.charged_at)
    FROM sponsors s
    JOIN charges c ON c.sponsor_id = s.id
   WHERE s.show_in_list
   GROUP BY s.id, s.nickname
   ORDER BY min(c.charged_at) DESC
   LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_pool_status()          TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_activity_feed(int)     TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_sponsor_wall(int)      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION settle_book_gift(bigint, int, text, text) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 9. RLS — 청소년 개인정보가 후원자에게 넘어가지 않도록 강제
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE sponsors                ENABLE ROW LEVEL SECURITY;
ALTER TABLE charges                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE book_gifts              ENABLE ROW LEVEL SECURITY;
ALTER TABLE consumption_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE completion_events       ENABLE ROW LEVEL SECURITY;
ALTER TABLE dokseo_settings         ENABLE ROW LEVEL SECURITY;

-- 후원자: 본인 행만
DROP POLICY IF EXISTS sponsors_self ON sponsors;
CREATE POLICY sponsors_self ON sponsors FOR SELECT
  USING (user_id = auth.uid() OR is_admin());
DROP POLICY IF EXISTS sponsors_self_update ON sponsors;
CREATE POLICY sponsors_self_update ON sponsors FOR UPDATE
  USING (user_id = auth.uid() OR is_admin());
DROP POLICY IF EXISTS sponsors_admin_write ON sponsors;
CREATE POLICY sponsors_admin_write ON sponsors FOR INSERT WITH CHECK (is_admin());

-- 후원 내역: 본인 것만 조회, 입력은 관리자(또는 도너스 동기화 서비스 키)
DROP POLICY IF EXISTS charges_own ON charges;
CREATE POLICY charges_own ON charges FOR SELECT
  USING (is_admin() OR sponsor_id IN (SELECT id FROM sponsors WHERE user_id = auth.uid()));
DROP POLICY IF EXISTS charges_admin_write ON charges;
CREATE POLICY charges_admin_write ON charges FOR INSERT WITH CHECK (is_admin());

-- 책 선물 건: 관리자 전용 (청소년 식별 정보·사진 포함)
DROP POLICY IF EXISTS book_gifts_admin ON book_gifts;
CREATE POLICY book_gifts_admin ON book_gifts FOR ALL
  USING (is_admin()) WITH CHECK (is_admin());
-- 청소년 본인은 자기 건만 조회 가능 (앱에서 "책 받음" 상태 표시용 — 후원 관련 문구는 노출하지 않음)
DROP POLICY IF EXISTS book_gifts_own ON book_gifts;
CREATE POLICY book_gifts_own ON book_gifts FOR SELECT USING (user_id = auth.uid());
-- 청소년 본인이 "책 받았어요" 기록 생성 (자격·값 검증은 book_gifts_check 트리거가 담당)
DROP POLICY IF EXISTS book_gifts_own_insert ON book_gifts;
CREATE POLICY book_gifts_own_insert ON book_gifts FOR INSERT WITH CHECK (user_id = auth.uid());

-- 차감 매핑: 본인 후원 건에 달린 것만 (금액만 보이고, book_gifts 는 읽을 수 없으므로 신원 노출 없음)
DROP POLICY IF EXISTS alloc_own ON consumption_allocations;
CREATE POLICY alloc_own ON consumption_allocations FOR SELECT
  USING (is_admin() OR charge_id IN (
    SELECT c.id FROM charges c JOIN sponsors s ON s.id = c.sponsor_id WHERE s.user_id = auth.uid()
  ));

-- 완료 카드: 본인 후원 건의 것만
DROP POLICY IF EXISTS completion_own ON completion_events;
CREATE POLICY completion_own ON completion_events FOR SELECT
  USING (is_admin() OR charge_id IN (
    SELECT c.id FROM charges c JOIN sponsors s ON s.id = c.sponsor_id WHERE s.user_id = auth.uid()
  ));

-- 설정: 누구나 조회(80/20 비율 공개), 수정은 관리자
DROP POLICY IF EXISTS settings_read ON dokseo_settings;
CREATE POLICY settings_read ON dokseo_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS settings_admin ON dokseo_settings;
CREATE POLICY settings_admin ON dokseo_settings FOR UPDATE USING (is_admin());


-- ════════════════════════════════════════════════════════════════════
-- 10. 스토리지 버킷 — 둘 다 비공개
-- ════════════════════════════════════════════════════════════════════

-- 10-1. 영수증 (관리자 전용)
INSERT INTO storage.buckets (id, name, public)
VALUES ('dokseo-receipts', 'dokseo-receipts', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "dokseo_receipts_admin" ON storage.objects;
CREATE POLICY "dokseo_receipts_admin" ON storage.objects FOR ALL
  USING (bucket_id = 'dokseo-receipts' AND is_admin())
  WITH CHECK (bucket_id = 'dokseo-receipts' AND is_admin());

-- 10-2. 책 수령 사진 (청소년이 올리고, 관리자만 열람)
--   ⚠️ 절대 public 으로 바꾸지 말 것. 얼굴을 가려도 배경·의상으로 간접 식별될 수 있어
--   후원자 화면에는 어떤 형태로도 내보내지 않는다.
INSERT INTO storage.buckets (id, name, public)
VALUES ('dokseo-proofs', 'dokseo-proofs', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "dokseo_proofs_own_insert" ON storage.objects;
CREATE POLICY "dokseo_proofs_own_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'dokseo-proofs' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "dokseo_proofs_read" ON storage.objects;
CREATE POLICY "dokseo_proofs_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'dokseo-proofs' AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));
