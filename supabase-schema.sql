-- ════════════════════════════════════════════════════════════════════
-- 한끗독서 — 청소년 독서 적립금 + 후원 정산 스키마
-- ════════════════════════════════════════════════════════════════════
--
-- 【전제】 한끗루틴과 "같은" Supabase 프로젝트에 추가하는 스키마입니다.
--   적립금을 인증 기록에서 계산하므로 certifications / routines 와 같은
--   DB 안에 있어야 합니다. → 실행 전 반드시 백업하고 스테이징에서 먼저.
--
-- 【프로그램 구조】
--   청소년이 끗짱과 매일 책을 읽고 인증한다
--     → 인증 1회마다 그 루틴에 정해진 금액이 적립된다
--     → 쌓인 적립금으로 인근 파트너 책방에 가서 책을 산다
--     → 책 산 기록(사진)을 올리면 "정산 대기"
--     → 담당자가 영수증 금액을 입력하면 후원금에서 FIFO로 차감된다
--
--   끗짱과 책방은 별개다. 책방은 책을 살 수 있는 허브 역할만 하며,
--   어느 책방에서 살지는 청소년이 목록에서 고른다.
--
-- 【핵심 규칙】
--   1. 후원금은 입금 즉시 도서기금/운영비로 분리 (비율은 dokseo_settings)
--   2. 차감은 FIFO — 가장 오래된 후원 건부터 소진
--   3. 책 구매와 정산 완료는 분리된 상태 (영수증 확인 전에는 차감되지 않음)
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
  id               int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  book_fund_rate   numeric(4,3) NOT NULL DEFAULT 0.800 CHECK (book_fund_rate > 0 AND book_fund_rate <= 1),
  milestone_amount int NOT NULL DEFAULT 100000,  -- "10만원 = 루틴 1개" 마일스톤 (해석 보류 중)
  updated_at       timestamptz DEFAULT now()
);
INSERT INTO dokseo_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;


-- ────────────────────────────────────────────────────────────────────
-- 2. 파트너 책방 — 적립금을 쓸 수 있는 허브
--    끗짱이 아니어도 된다. 책을 살 수 있는 곳이면 된다.
--    위치·영업시간을 앱에서 바로 보여줘서, 담당자가 매 회차 수기로
--    방문 안내를 보내지 않아도 되게 함
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookstores (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  name        text NOT NULL,
  region      text,                       -- 예) 강원 속초 — 청소년이 내 동네를 찾는 기준
  address     text,                       -- 길찾기 링크에 그대로 쓰임
  hours       text,                       -- 예) 평일 11:00~19:00
  closed_days text,                       -- 예) 매주 월요일 휴무
  phone       text,
  link        text,                       -- 인스타그램 또는 홈페이지
  intro       text,                       -- 한 줄 소개
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bookstores_region_idx ON bookstores (region) WHERE active;


-- ────────────────────────────────────────────────────────────────────
-- 3. 한끗루틴 테이블에 붙는 컬럼
-- ────────────────────────────────────────────────────────────────────

-- 어떤 루틴이 한끗독서 루틴인지. 체크된 루틴에서만 적립·구매 화면이 열린다
ALTER TABLE routines ADD COLUMN IF NOT EXISTS dokseo boolean NOT NULL DEFAULT false;

-- 인증 1회당 적립액(원). 루틴마다 기간·성격이 달라 루틴별로 정한다
ALTER TABLE routines ADD COLUMN IF NOT EXISTS dokseo_amount_per_cert int NOT NULL DEFAULT 0;

-- 독서루틴 인증에 딸리는 기록
--   quote      : 옮겨 적고 싶은 문장 (필사) — 선택
--   book_title : 지금 읽는 책. 다음 인증에서 자동으로 채워짐 — 선택
--   page_end   : 오늘까지 읽은 쪽. 전날보다 줄면 앱이 부드럽게 물어보되 막지는 않음 — 선택
ALTER TABLE certifications ADD COLUMN IF NOT EXISTS quote      text;
ALTER TABLE certifications ADD COLUMN IF NOT EXISTS book_title text;
ALTER TABLE certifications ADD COLUMN IF NOT EXISTS page_end   int;

-- 후원자에게 보여줄 문장은 운영진이 고른 것만. 아이가 문장 대신 개인적인
-- 이야기를 적었을 수 있어 자동 노출하지 않는다
ALTER TABLE certifications ADD COLUMN IF NOT EXISTS quote_public boolean NOT NULL DEFAULT false;


-- ────────────────────────────────────────────────────────────────────
-- 4. 책 구매 기록 — 정산의 단위
--    청소년이 책방에서 적립금으로 책을 사고, 책으로 얼굴을 가린 사진을
--    올리면 여기에 'pending' 으로 생성된다
--    ⚠️ 개인 식별 정보(user_id, 사진)를 담으므로 후원자는 조회 불가
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS book_purchases (
  id              bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id         uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  routine_id      bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,  -- 적립금이 쌓인 루틴
  bookstore_id    bigint REFERENCES bookstores(id) ON DELETE SET NULL,        -- 어디서 샀는지
  proof_photo_url text,                                  -- 책+얼굴가림 사진 (내부 확인용)
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','settled','void')),
  amount          int CHECK (amount IS NULL OR amount > 0),  -- 영수증 기준 실제 금액
  receipt_url     text,
  note            text,
  settled_by      uuid REFERENCES auth.users ON DELETE SET NULL,
  settled_at      timestamptz,
  created_at      timestamptz DEFAULT now(),
  CONSTRAINT book_purchases_settled_needs_amount
    CHECK (status <> 'settled' OR (amount IS NOT NULL AND settled_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS book_purchases_status_idx ON book_purchases (status, created_at);
CREATE INDEX IF NOT EXISTS book_purchases_user_idx   ON book_purchases (user_id, routine_id);
-- 정산 대기 건은 1인 1루틴에 하나만 (앞 건이 정산돼야 다음 구매를 기록)
CREATE UNIQUE INDEX IF NOT EXISTS book_purchases_one_pending_idx
  ON book_purchases (user_id, routine_id) WHERE status = 'pending';


-- ────────────────────────────────────────────────────────────────────
-- 5. 적립금 잔액
--    따로 저장하지 않고 인증 기록에서 계산한다. 저장된 잔액과 실제 인증이
--    어긋날 여지를 아예 없애기 위함.
--      잔액 = (그 루틴의 내 인증 수 × 인증당 적립액) − (정산 완료된 구매 합계)
--    정산 대기 중인 건은 금액이 아직 없으므로 잔액에서 빼지 않는다.
--    대신 대기 건이 있으면 새 구매를 기록할 수 없다(위 유니크 인덱스).
-- ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION dokseo_balance(p_user uuid, p_routine bigint)
RETURNS int AS $$
  SELECT GREATEST(0,
    COALESCE((SELECT count(*) FROM certifications c
               WHERE c.routine_id = p_routine AND c.user_id = p_user), 0)
    * COALESCE((SELECT r.dokseo_amount_per_cert FROM routines r
                 WHERE r.id = p_routine AND r.dokseo), 0)
    - COALESCE((SELECT sum(p.amount) FROM book_purchases p
                 WHERE p.user_id = p_user AND p.routine_id = p_routine
                   AND p.status = 'settled'), 0)
  )::int;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_balance(uuid, bigint) TO authenticated;


-- 청소년이 직접 올리는 구매 기록의 자격·값 검증
--   자격: 독서루틴이고, 적립금 잔액이 남아 있을 것
--   청소년이 올린 행은 금액·정산 관련 값을 절대 담을 수 없게 강제로 비움
CREATE OR REPLACE FUNCTION check_book_purchase_insert() RETURNS trigger AS $$
DECLARE
  v_dokseo  boolean;
  v_balance int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status      := 'pending';
  NEW.amount      := NULL;
  NEW.receipt_url := NULL;
  NEW.settled_by  := NULL;
  NEW.settled_at  := NULL;

  SELECT dokseo INTO v_dokseo FROM routines WHERE id = NEW.routine_id;
  IF NOT COALESCE(v_dokseo, false) THEN
    RAISE EXCEPTION '한끗독서 루틴이 아닙니다';
  END IF;

  v_balance := dokseo_balance(NEW.user_id, NEW.routine_id);
  IF v_balance <= 0 THEN
    RAISE EXCEPTION '아직 쓸 수 있는 적립금이 없습니다';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS book_purchases_check ON book_purchases;
CREATE TRIGGER book_purchases_check BEFORE INSERT ON book_purchases
  FOR EACH ROW EXECUTE FUNCTION check_book_purchase_insert();


-- ────────────────────────────────────────────────────────────────────
-- 6. 후원자
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
-- 7. 후원 내역
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

-- 후원 입력 시 자동 분리 (원 단위 내림, 잔돈은 도서기금 쪽으로)
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
-- 8. FIFO 차감 매핑 — 어느 후원 건에서 얼마가 빠져나갔는지
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS consumption_allocations (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  purchase_id bigint NOT NULL REFERENCES book_purchases(id) ON DELETE RESTRICT,
  charge_id   bigint NOT NULL REFERENCES charges(id)        ON DELETE RESTRICT,
  amount      int    NOT NULL CHECK (amount > 0),
  created_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS alloc_charge_idx   ON consumption_allocations (charge_id);
CREATE INDEX IF NOT EXISTS alloc_purchase_idx ON consumption_allocations (purchase_id);


-- ────────────────────────────────────────────────────────────────────
-- 9. 후원 소진 완료 이벤트 — 후원자 대시보드의 "완료 카드"
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS completion_events (
  id              bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  charge_id       bigint NOT NULL UNIQUE REFERENCES charges(id) ON DELETE CASCADE,
  students_count  int NOT NULL,
  purchases_count int NOT NULL,
  -- 이 후원이 받쳐준 독서 일수. 차감액 ÷ 인증당 적립액으로 환산한다.
  -- 후원자에게 "책 몇 권"이 아니라 "며칠의 독서"를 보여주기 위한 값
  reading_days    int NOT NULL DEFAULT 0,
  total_amount    int NOT NULL,
  message         text,
  created_at      timestamptz DEFAULT now()
);


-- ════════════════════════════════════════════════════════════════════
-- 10. 정산 함수 — 관리자가 영수증 금액을 입력하면 FIFO로 차감
--     금액 확정과 차감이 한 트랜잭션에서 원자적으로 처리됨
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION settle_book_purchase(
  p_purchase_id bigint,
  p_amount      int,
  p_receipt_url text DEFAULT NULL,
  p_note        text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_left    int := p_amount;
  v_take    int;
  v_charge  record;
  v_allocs  jsonb := '[]'::jsonb;
  v_pool    int;
  v_user    uuid;
  v_routine bigint;
  v_balance int;
BEGIN
  IF NOT is_admin() THEN
    RAISE EXCEPTION '정산 권한이 없습니다';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION '정산 금액이 올바르지 않습니다';
  END IF;

  -- 대상 건 잠금 + 상태 확인
  SELECT user_id, routine_id INTO v_user, v_routine
    FROM book_purchases WHERE id = p_purchase_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 대기 상태의 건이 아닙니다 (id=%)', p_purchase_id;
  END IF;

  -- 적립금을 넘겨 쓸 수는 없다
  v_balance := dokseo_balance(v_user, v_routine);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION '적립금 잔액을 넘습니다 (잔액 %원 / 입력 %원)', v_balance, p_amount;
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

    INSERT INTO consumption_allocations (purchase_id, charge_id, amount)
    VALUES (p_purchase_id, v_charge.id, v_take);

    UPDATE charges
       SET remaining_amount = remaining_amount - v_take,
           status       = CASE WHEN remaining_amount - v_take = 0 THEN 'completed' ELSE status END,
           completed_at = CASE WHEN remaining_amount - v_take = 0 THEN now() ELSE completed_at END
     WHERE id = v_charge.id;

    v_allocs := v_allocs || jsonb_build_object('charge_id', v_charge.id, 'amount', v_take);
    v_left := v_left - v_take;

    -- 소진 완료된 후원 건은 완료 카드 생성
    INSERT INTO completion_events (charge_id, students_count, purchases_count, reading_days, total_amount, message)
    SELECT c.id,
           count(DISTINCT p.user_id),
           count(DISTINCT p.id),
           COALESCE(sum(a.amount::numeric / NULLIF(r.dokseo_amount_per_cert, 0)), 0)::int,
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
     SET status      = 'settled',
         amount      = p_amount,
         receipt_url = COALESCE(p_receipt_url, receipt_url),
         note        = COALESCE(p_note, note),
         settled_by  = auth.uid(),
         settled_at  = now()
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('purchase_id', p_purchase_id, 'amount', p_amount, 'allocations', v_allocs);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ════════════════════════════════════════════════════════════════════
-- 11. 공개 집계 — 후원자 대시보드용
--     개별 청소년을 식별할 수 없는 형태로만 반환 (SECURITY DEFINER)
-- ════════════════════════════════════════════════════════════════════

-- 11-1. 도서기금 풀 현황
CREATE OR REPLACE FUNCTION dokseo_pool_status() RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'total_donated',    COALESCE((SELECT sum(amount) FROM charges), 0),
    'book_fund',        COALESCE((SELECT sum(book_fund_amount) FROM charges), 0),
    'operation_fee',    COALESCE((SELECT sum(operation_fee_amount) FROM charges), 0),
    'remaining',        COALESCE((SELECT sum(remaining_amount) FROM charges), 0),
    'spent',            COALESCE((SELECT sum(amount) FROM consumption_allocations), 0),
    'books_bought',     COALESCE((SELECT count(*) FROM book_purchases WHERE status = 'settled'), 0),
    'books_pending',    COALESCE((SELECT count(*) FROM book_purchases WHERE status = 'pending'), 0),
    'students_reached', COALESCE((SELECT count(DISTINCT user_id) FROM book_purchases WHERE status <> 'void'), 0),
    'sponsors_count',   COALESCE((SELECT count(DISTINCT sponsor_id) FROM charges), 0),
    'bookstores_count', COALESCE((SELECT count(*) FROM bookstores WHERE active), 0)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 11-2. 익명 인증 피드 — 날짜별 인증 수·인원 수만 (누가 했는지는 반환하지 않음)
CREATE OR REPLACE FUNCTION dokseo_activity_feed(p_days int DEFAULT 14)
RETURNS TABLE (day date, cert_count bigint, student_count bigint) AS $$
  SELECT (c.created_at AT TIME ZONE 'Asia/Seoul')::date AS day,
         count(*)                    AS cert_count,
         count(DISTINCT c.user_id)   AS student_count
    FROM certifications c
    JOIN routines r ON r.id = c.routine_id AND r.dokseo
   WHERE c.created_at >= now() - make_interval(days => p_days)
   GROUP BY 1
   ORDER BY 1 DESC;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 11-2-b. 읽기 기록 집계 — 후원이 산 게 "시간"이라는 걸 숫자로 보여주기 위함
--   누적 쪽수: page_end 는 "그날까지 읽은 쪽"이라 누적이 아니므로,
--   (사람 × 루틴 × 책)별 최댓값을 더해야 실제로 읽은 양이 된다
CREATE OR REPLACE FUNCTION dokseo_reading_stats() RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'pages_read', COALESCE((
      SELECT sum(mx) FROM (
        SELECT max(c.page_end) AS mx
          FROM certifications c
          JOIN routines r ON r.id = c.routine_id AND r.dokseo
         WHERE c.page_end IS NOT NULL
         GROUP BY c.user_id, c.routine_id, c.book_title
      ) t), 0),
    'books_titles', COALESCE((
      SELECT count(DISTINCT c.book_title)
        FROM certifications c
        JOIN routines r ON r.id = c.routine_id AND r.dokseo
       WHERE c.book_title IS NOT NULL AND c.book_title <> ''), 0),
    'cert_total', COALESCE((
      SELECT count(*) FROM certifications c
        JOIN routines r ON r.id = c.routine_id AND r.dokseo), 0),
    'students_total', COALESCE((
      SELECT count(DISTINCT c.user_id) FROM certifications c
        JOIN routines r ON r.id = c.routine_id AND r.dokseo), 0)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 11-2-c. 아이들이 옮겨 적은 문장 — 운영진이 공개로 고른 것만.
--   ⚠️ user_id 를 절대 반환하지 않는다. 문장과 책 제목만 나간다
CREATE OR REPLACE FUNCTION dokseo_public_quotes(p_limit int DEFAULT 12)
RETURNS TABLE (quote text, book_title text, day date) AS $$
  SELECT c.quote, c.book_title, (c.created_at AT TIME ZONE 'Asia/Seoul')::date
    FROM certifications c
    JOIN routines r ON r.id = c.routine_id AND r.dokseo
   WHERE c.quote_public AND c.quote IS NOT NULL AND c.quote <> ''
   ORDER BY c.created_at DESC
   LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 11-2-d. 요즘 읽고 있는 책 — 제목만. 누가 읽는지는 반환하지 않는다
CREATE OR REPLACE FUNCTION dokseo_books_reading(p_limit int DEFAULT 20)
RETURNS TABLE (book_title text, readers bigint) AS $$
  SELECT c.book_title, count(DISTINCT c.user_id)
    FROM certifications c
    JOIN routines r ON r.id = c.routine_id AND r.dokseo
   WHERE c.book_title IS NOT NULL AND c.book_title <> ''
   GROUP BY c.book_title
   ORDER BY max(c.created_at) DESC
   LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 11-3. 함께하는 후원자 — 노출 동의한 사람의 닉네임만
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

GRANT EXECUTE ON FUNCTION dokseo_pool_status()      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_activity_feed(int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_reading_stats()    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_public_quotes(int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_books_reading(int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_sponsor_wall(int)  TO anon, authenticated;
GRANT EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- 12. RLS — 청소년 개인정보가 후원자에게 넘어가지 않도록 강제
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE bookstores              ENABLE ROW LEVEL SECURITY;
ALTER TABLE book_purchases          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sponsors                ENABLE ROW LEVEL SECURITY;
ALTER TABLE charges                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE consumption_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE completion_events       ENABLE ROW LEVEL SECURITY;
ALTER TABLE dokseo_settings         ENABLE ROW LEVEL SECURITY;

-- 책방: 가게 정보라 조회는 열어두고, 등록·수정은 관리자만
DROP POLICY IF EXISTS bookstores_read ON bookstores;
CREATE POLICY bookstores_read ON bookstores FOR SELECT USING (true);
DROP POLICY IF EXISTS bookstores_admin ON bookstores;
CREATE POLICY bookstores_admin ON bookstores FOR ALL
  USING (is_admin()) WITH CHECK (is_admin());

-- 구매 기록: 관리자 전체, 청소년은 자기 것만 (후원자는 접근 불가)
DROP POLICY IF EXISTS book_purchases_admin ON book_purchases;
CREATE POLICY book_purchases_admin ON book_purchases FOR ALL
  USING (is_admin()) WITH CHECK (is_admin());
DROP POLICY IF EXISTS book_purchases_own ON book_purchases;
CREATE POLICY book_purchases_own ON book_purchases FOR SELECT USING (user_id = auth.uid());
DROP POLICY IF EXISTS book_purchases_own_insert ON book_purchases;
CREATE POLICY book_purchases_own_insert ON book_purchases FOR INSERT WITH CHECK (user_id = auth.uid());

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

-- 차감 매핑: 본인 후원 건에 달린 것만 (금액만 보이고, book_purchases 는 읽을 수 없어 신원 노출 없음)
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

-- 설정: 누구나 조회(분리 비율 공개), 수정은 관리자
DROP POLICY IF EXISTS settings_read ON dokseo_settings;
CREATE POLICY settings_read ON dokseo_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS settings_admin ON dokseo_settings;
CREATE POLICY settings_admin ON dokseo_settings FOR UPDATE USING (is_admin());


-- ════════════════════════════════════════════════════════════════════
-- 13. 스토리지 버킷 — 둘 다 비공개
-- ════════════════════════════════════════════════════════════════════

-- 13-1. 영수증 (관리자 전용)
INSERT INTO storage.buckets (id, name, public)
VALUES ('dokseo-receipts', 'dokseo-receipts', false)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "dokseo_receipts_admin" ON storage.objects;
CREATE POLICY "dokseo_receipts_admin" ON storage.objects FOR ALL
  USING (bucket_id = 'dokseo-receipts' AND is_admin())
  WITH CHECK (bucket_id = 'dokseo-receipts' AND is_admin());

-- 13-2. 책 구매 사진 (청소년이 올리고, 관리자만 열람)
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
