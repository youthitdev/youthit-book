-- ════════════════════════════════════════════════════════════════════
-- 한끗독서 — 독립 서비스 스키마
-- ════════════════════════════════════════════════════════════════════
--
-- 【전제】 한끗독서 전용 Supabase 프로젝트에 통째로 적용합니다.
--   한끗루틴과 어떤 테이블도 공유하지 않습니다. 참여자·루틴·인증까지
--   전부 이 파일 안에 자체 정의되어 있습니다.
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
--   3. 책 구매와 정산 완료는 분리 (영수증 확인 전에는 차감되지 않음)
--   4. 청소년은 후원의 존재를 알지 못한다. 개인 식별 정보는 후원자에게
--      어떤 형태로도 나가지 않는다 (RLS로 강제)
-- ════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────
-- 0. 관리자 판별
-- ────────────────────────────────────────────────────────────────────
-- ⚠️ COALESCE 를 빼지 말 것. 로그인하지 않으면 auth.email() 이 NULL 이고
--    NULL IN (...) 은 false 가 아니라 NULL 이다. 그러면
--    IF NOT is_admin() THEN RAISE ... 형태의 검사가 통째로 통과해 버린다
CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean AS $$
  SELECT COALESCE(auth.email() IN ('dev@youthvoice.or.kr', 'yv@youthvoice.or.kr'), false);
$$ LANGUAGE sql SECURITY DEFINER STABLE;


-- ────────────────────────────────────────────────────────────────────
-- 1. 설정
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS dokseo_settings (
  id               int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  book_fund_rate   numeric(4,3) NOT NULL DEFAULT 0.800 CHECK (book_fund_rate > 0 AND book_fund_rate <= 1),
  milestone_amount int NOT NULL DEFAULT 100000,
  updated_at       timestamptz DEFAULT now()
);
INSERT INTO dokseo_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;


-- ────────────────────────────────────────────────────────────────────
-- 2. 참여자 — 청소년과 끗짱
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS profiles (
  id         uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  name       text NOT NULL,
  -- ⚠️ 옛 값이다. migration-33 에서 ('youth','adult') 로 바뀌었고
  --    끗짱 여부는 can_lead 컬럼으로 옮겼다. 여기 값을 믿지 말 것
  role       text NOT NULL DEFAULT 'youth' CHECK (role IN ('youth','kkutjjang')),
  region     text,                        -- 가까운 책방을 먼저 보여주는 데 씀
  created_at timestamptz DEFAULT now()
);


-- ────────────────────────────────────────────────────────────────────
-- 3. 독서루틴
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS routines (
  id                bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  title             text NOT NULL,
  emoji             text DEFAULT '📚',
  description       text,
  cert_guide        text,                     -- "이렇게 인증해 주세요"
  start_date        date,
  end_date          date,
  max_people        int NOT NULL DEFAULT 10,
  -- 인증 1회당 적립액(원). 루틴마다 기간·성격이 달라 루틴별로 정한다
  amount_per_cert   int NOT NULL DEFAULT 0 CHECK (amount_per_cert >= 0),
  camera_only       boolean NOT NULL DEFAULT false,  -- 실시간 촬영만 허용
  status            text NOT NULL DEFAULT 'recruit' CHECK (status IN ('recruit','active','done')),
  led_by            uuid REFERENCES auth.users ON DELETE SET NULL,   -- 끗짱
  created_at        timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS routine_participants (
  routine_id bigint REFERENCES routines(id) ON DELETE CASCADE,
  user_id    uuid   REFERENCES auth.users   ON DELETE CASCADE,
  status     text   NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected')),
  note       text,
  joined_at  timestamptz DEFAULT now(),
  PRIMARY KEY (routine_id, user_id)
);


-- ────────────────────────────────────────────────────────────────────
-- 4. 독서 인증
--    인증의 중심은 "책 읽는 순간" 사진 한 장. 나머지는 모두 선택이라
--    매일의 부담은 사진 한 장이고, 더 남기고 싶은 사람만 더 남긴다
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS certifications (
  id           bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  routine_id   bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  user_id      uuid   NOT NULL REFERENCES auth.users  ON DELETE CASCADE,
  photo_urls   text[] NOT NULL DEFAULT '{}',
  quote        text,        -- 옮겨 적고 싶은 문장 (필사)
  book_title   text,        -- 지금 읽는 책. 다음 인증에서 자동으로 채워짐
  page_end     int,         -- 오늘까지 읽은 쪽
  content      text,        -- 더 남기고 싶은 말
  -- 후원자에게 보여줄 문장은 운영진이 고른 것만. 아이가 문장 대신 개인적인
  -- 이야기를 적었을 수 있어 자동 노출하지 않는다
  quote_public boolean NOT NULL DEFAULT false,
  -- 하루 1회 제약에 쓰는 한국 날짜. AT TIME ZONE 은 STABLE 이라 인덱스 식에
  -- 직접 못 쓰기 때문에, 넣을 때 값으로 굳혀서 컬럼에 담는다
  cert_date    date NOT NULL DEFAULT ((now() AT TIME ZONE 'Asia/Seoul')::date),
  created_at   timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS certs_routine_user_idx ON certifications (routine_id, user_id);
CREATE INDEX IF NOT EXISTS certs_created_idx      ON certifications (created_at DESC);

-- 하루에 한 번만 인증
CREATE UNIQUE INDEX IF NOT EXISTS certs_once_a_day_idx
  ON certifications (routine_id, user_id, cert_date);

CREATE TABLE IF NOT EXISTS cert_comments (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  cert_id    bigint NOT NULL REFERENCES certifications(id) ON DELETE CASCADE,
  user_id    uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  content    text   NOT NULL,
  created_at timestamptz DEFAULT now()
);


-- ────────────────────────────────────────────────────────────────────
-- 5. 파트너 책방 — 적립금을 쓸 수 있는 허브
--    끗짱이 아니어도 된다. 책을 살 수 있는 곳이면 된다.
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS bookstores (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  name        text NOT NULL,
  region      text,                       -- 예) 강원 속초 — 청소년이 내 동네를 찾는 기준
  address     text,                       -- 길찾기 링크에 그대로 쓰임
  hours       text,
  closed_days text,
  phone       text,
  link        text,                       -- 인스타그램 또는 홈페이지
  intro       text,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bookstores_region_idx ON bookstores (region) WHERE active;


-- ────────────────────────────────────────────────────────────────────
-- 6. 책 구매 기록 — 정산의 단위
--    ⚠️ 개인 식별 정보(user_id, 사진)를 담으므로 후원자는 조회 불가
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS book_purchases (
  id              bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  user_id         uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  routine_id      bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  bookstore_id    bigint REFERENCES bookstores(id) ON DELETE SET NULL,
  proof_photo_url text,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','settled','void')),
  amount          int CHECK (amount IS NULL OR amount > 0),
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
-- 7. 적립금 잔액
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
    * COALESCE((SELECT r.amount_per_cert FROM routines r WHERE r.id = p_routine), 0)
    - COALESCE((SELECT sum(p.amount) FROM book_purchases p
                 WHERE p.user_id = p_user AND p.routine_id = p_routine
                   AND p.status = 'settled'), 0)
  )::int;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_balance(uuid, bigint) TO authenticated;

-- 청소년이 직접 올리는 구매 기록의 자격·값 검증
CREATE OR REPLACE FUNCTION check_book_purchase_insert() RETURNS trigger AS $$
DECLARE v_balance int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status      := 'pending';
  NEW.amount      := NULL;
  NEW.receipt_url := NULL;
  NEW.settled_by  := NULL;
  NEW.settled_at  := NULL;

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
-- 8. 후원자 · 후원 내역
-- ────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS sponsors (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid UNIQUE REFERENCES auth.users ON DELETE SET NULL,
  email        text UNIQUE NOT NULL,
  nickname     text NOT NULL,
  show_in_list boolean NOT NULL DEFAULT true,
  created_at   timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS charges (
  id                   bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  sponsor_id           uuid NOT NULL REFERENCES sponsors(id) ON DELETE RESTRICT,
  amount               int  NOT NULL CHECK (amount > 0),
  book_fund_amount     int  NOT NULL CHECK (book_fund_amount >= 0),
  operation_fee_amount int  NOT NULL CHECK (operation_fee_amount >= 0),
  remaining_amount     int  NOT NULL CHECK (remaining_amount >= 0),
  status               text NOT NULL DEFAULT 'active' CHECK (status IN ('active','completed')),
  source               text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual','donus')),
  external_ref         text,
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
DECLARE v_rate numeric; v_op int;
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

CREATE TABLE IF NOT EXISTS consumption_allocations (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  purchase_id bigint NOT NULL REFERENCES book_purchases(id) ON DELETE RESTRICT,
  charge_id   bigint NOT NULL REFERENCES charges(id)        ON DELETE RESTRICT,
  amount      int    NOT NULL CHECK (amount > 0),
  created_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS alloc_charge_idx   ON consumption_allocations (charge_id);
CREATE INDEX IF NOT EXISTS alloc_purchase_idx ON consumption_allocations (purchase_id);

CREATE TABLE IF NOT EXISTS completion_events (
  id              bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  charge_id       bigint NOT NULL UNIQUE REFERENCES charges(id) ON DELETE CASCADE,
  students_count  int NOT NULL,
  purchases_count int NOT NULL,
  -- 이 후원이 받쳐준 독서 일수. 차감액 ÷ 인증당 적립액으로 환산한다
  reading_days    int NOT NULL DEFAULT 0,
  total_amount    int NOT NULL,
  message         text,
  created_at      timestamptz DEFAULT now()
);


-- ════════════════════════════════════════════════════════════════════
-- 9. 정산 함수 — 영수증 금액 입력 시 FIFO로 차감 (원자적)
-- ════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION settle_book_purchase(
  p_purchase_id bigint,
  p_amount      int,
  p_receipt_url text DEFAULT NULL,
  p_note        text DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE
  v_left int := p_amount; v_take int; v_charge record;
  v_allocs jsonb := '[]'::jsonb; v_pool int;
  v_user uuid; v_routine bigint; v_balance int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN RAISE EXCEPTION '정산 금액이 올바르지 않습니다'; END IF;

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

    INSERT INTO completion_events (charge_id, students_count, purchases_count, reading_days, total_amount, message)
    SELECT c.id,
           count(DISTINCT p.user_id),
           count(DISTINCT p.id),
           COALESCE(sum(a.amount::numeric / NULLIF(r.amount_per_cert, 0)), 0)::int,
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


-- ════════════════════════════════════════════════════════════════════
-- 10. 공개 집계 — 후원자 대시보드용
--     개별 청소년을 식별할 수 없는 형태로만 반환 (SECURITY DEFINER)
-- ════════════════════════════════════════════════════════════════════
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

CREATE OR REPLACE FUNCTION dokseo_activity_feed(p_days int DEFAULT 14)
RETURNS TABLE (day date, cert_count bigint, student_count bigint) AS $$
  SELECT (created_at AT TIME ZONE 'Asia/Seoul')::date,
         count(*), count(DISTINCT user_id)
    FROM certifications
   WHERE created_at >= now() - make_interval(days => p_days)
   GROUP BY 1 ORDER BY 1 DESC;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 누적 쪽수: page_end 는 "그날까지 읽은 쪽"이라 누적이 아니므로,
-- (사람 × 루틴 × 책)별 최댓값을 더해야 실제로 읽은 양이 된다
CREATE OR REPLACE FUNCTION dokseo_reading_stats() RETURNS jsonb AS $$
  SELECT jsonb_build_object(
    'pages_read', COALESCE((
      SELECT sum(mx) FROM (
        SELECT max(page_end) AS mx FROM certifications
         WHERE page_end IS NOT NULL
         GROUP BY user_id, routine_id, book_title) t), 0),
    'books_titles',   COALESCE((SELECT count(DISTINCT book_title) FROM certifications
                                 WHERE book_title IS NOT NULL AND book_title <> ''), 0),
    'cert_total',     COALESCE((SELECT count(*) FROM certifications), 0),
    'students_total', COALESCE((SELECT count(DISTINCT user_id) FROM certifications), 0)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ⚠️ user_id 를 절대 반환하지 않는다. 문장과 책 제목만 나간다
CREATE OR REPLACE FUNCTION dokseo_public_quotes(p_limit int DEFAULT 12)
RETURNS TABLE (quote text, book_title text, day date) AS $$
  SELECT quote, book_title, (created_at AT TIME ZONE 'Asia/Seoul')::date
    FROM certifications
   WHERE quote_public AND quote IS NOT NULL AND quote <> ''
   ORDER BY created_at DESC LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION dokseo_books_reading(p_limit int DEFAULT 20)
RETURNS TABLE (book_title text, readers bigint) AS $$
  SELECT book_title, count(DISTINCT user_id)
    FROM certifications
   WHERE book_title IS NOT NULL AND book_title <> ''
   GROUP BY book_title ORDER BY max(created_at) DESC LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION dokseo_sponsor_wall(p_limit int DEFAULT 50)
RETURNS TABLE (nickname text, joined_at timestamptz) AS $$
  SELECT s.nickname, min(c.charged_at)
    FROM sponsors s JOIN charges c ON c.sponsor_id = s.id
   WHERE s.show_in_list
   GROUP BY s.id, s.nickname ORDER BY min(c.charged_at) DESC LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_pool_status()      TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_activity_feed(int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_reading_stats()    TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_public_quotes(int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_books_reading(int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION dokseo_sponsor_wall(int)  TO anon, authenticated;
-- ⚠️ 함수를 만들면 PUBLIC 에 EXECUTE 가 기본으로 붙는다. authenticated 에만
--    GRANT 해도 익명이 호출할 수 있으므로, 반드시 PUBLIC 에서 회수해야 한다
REVOKE EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION settle_book_purchase(bigint, int, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION dokseo_balance(uuid, bigint) FROM PUBLIC, anon;


-- ════════════════════════════════════════════════════════════════════
-- 11. 가입 시 프로필 자동 생성
-- ════════════════════════════════════════════════════════════════════
-- 이 트리거가 실패해도 가입 자체는 막지 않는다.
-- 한끗루틴에서 같은 트리거가 500 에러를 내 가입이 통째로 막혔던 적이 있어서,
-- 실패하면 조용히 넘기고 앱이 프로필을 직접 만들도록 둔다
CREATE OR REPLACE FUNCTION handle_new_user() RETURNS trigger AS $$
BEGIN
  BEGIN
    INSERT INTO profiles (id, name, role)
    VALUES (NEW.id,
            COALESCE(NEW.raw_user_meta_data->>'name', '이름없음'),
            COALESCE(NEW.raw_user_meta_data->>'role', 'youth'))
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '프로필 자동 생성 실패 (가입은 계속): %', SQLERRM;
  END;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- ════════════════════════════════════════════════════════════════════
-- 12. RLS
-- ════════════════════════════════════════════════════════════════════
ALTER TABLE profiles                ENABLE ROW LEVEL SECURITY;
ALTER TABLE routines                ENABLE ROW LEVEL SECURITY;
ALTER TABLE routine_participants    ENABLE ROW LEVEL SECURITY;
ALTER TABLE certifications          ENABLE ROW LEVEL SECURITY;
ALTER TABLE cert_comments           ENABLE ROW LEVEL SECURITY;
ALTER TABLE bookstores              ENABLE ROW LEVEL SECURITY;
ALTER TABLE book_purchases          ENABLE ROW LEVEL SECURITY;
ALTER TABLE sponsors                ENABLE ROW LEVEL SECURITY;
ALTER TABLE charges                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE consumption_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE completion_events       ENABLE ROW LEVEL SECURITY;
ALTER TABLE dokseo_settings         ENABLE ROW LEVEL SECURITY;

-- 프로필: 로그인한 사람끼리는 이름을 볼 수 있고, 수정은 본인만
DROP POLICY IF EXISTS profiles_read ON profiles;
CREATE POLICY profiles_read ON profiles FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS profiles_self_update ON profiles;
CREATE POLICY profiles_self_update ON profiles FOR UPDATE USING (id = auth.uid() OR is_admin());
-- 위 트리거가 실패했을 때 앱이 직접 프로필을 만들 수 있어야 한다
DROP POLICY IF EXISTS profiles_self_insert ON profiles;
CREATE POLICY profiles_self_insert ON profiles FOR INSERT WITH CHECK (id = auth.uid());

-- 루틴: 조회는 공개(모집 홍보), 생성·수정은 관리자
DROP POLICY IF EXISTS routines_read ON routines;
CREATE POLICY routines_read ON routines FOR SELECT USING (true);
DROP POLICY IF EXISTS routines_admin ON routines;
CREATE POLICY routines_admin ON routines FOR ALL USING (is_admin()) WITH CHECK (is_admin());

-- 참여: 본인 신청, 승인은 그 루틴 끗짱이나 관리자
DROP POLICY IF EXISTS parts_read ON routine_participants;
CREATE POLICY parts_read ON routine_participants FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS parts_self_insert ON routine_participants;
CREATE POLICY parts_self_insert ON routine_participants FOR INSERT WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS parts_leader_update ON routine_participants;
CREATE POLICY parts_leader_update ON routine_participants FOR UPDATE
  USING (is_admin() OR routine_id IN (SELECT id FROM routines WHERE led_by = auth.uid()));

-- 인증: 같은 루틴 참여자끼리 보이고, 쓰는 건 본인만
DROP POLICY IF EXISTS certs_read ON certifications;
CREATE POLICY certs_read ON certifications FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS certs_own_write ON certifications;
CREATE POLICY certs_own_write ON certifications FOR INSERT WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS certs_own_update ON certifications;
CREATE POLICY certs_own_update ON certifications FOR UPDATE
  USING (user_id = auth.uid() OR is_admin());
DROP POLICY IF EXISTS certs_own_delete ON certifications;
CREATE POLICY certs_own_delete ON certifications FOR DELETE
  USING (user_id = auth.uid() OR is_admin());

DROP POLICY IF EXISTS comments_read ON cert_comments;
CREATE POLICY comments_read ON cert_comments FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS comments_own ON cert_comments;
CREATE POLICY comments_own ON cert_comments FOR INSERT WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS comments_own_delete ON cert_comments;
CREATE POLICY comments_own_delete ON cert_comments FOR DELETE
  USING (user_id = auth.uid() OR is_admin());

-- 책방: 가게 정보라 조회는 열어두고, 등록·수정은 관리자만
DROP POLICY IF EXISTS bookstores_read ON bookstores;
CREATE POLICY bookstores_read ON bookstores FOR SELECT USING (true);
DROP POLICY IF EXISTS bookstores_admin ON bookstores;
CREATE POLICY bookstores_admin ON bookstores FOR ALL USING (is_admin()) WITH CHECK (is_admin());

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
CREATE POLICY sponsors_self ON sponsors FOR SELECT USING (user_id = auth.uid() OR is_admin());
DROP POLICY IF EXISTS sponsors_self_update ON sponsors;
CREATE POLICY sponsors_self_update ON sponsors FOR UPDATE USING (user_id = auth.uid() OR is_admin());
DROP POLICY IF EXISTS sponsors_admin_write ON sponsors;
CREATE POLICY sponsors_admin_write ON sponsors FOR INSERT WITH CHECK (is_admin());

DROP POLICY IF EXISTS charges_own ON charges;
CREATE POLICY charges_own ON charges FOR SELECT
  USING (is_admin() OR sponsor_id IN (SELECT id FROM sponsors WHERE user_id = auth.uid()));
DROP POLICY IF EXISTS charges_admin_write ON charges;
CREATE POLICY charges_admin_write ON charges FOR INSERT WITH CHECK (is_admin());

-- 차감 매핑: 본인 후원 건에 달린 것만 (금액만 보이고, book_purchases 는 못 읽어 신원 노출 없음)
DROP POLICY IF EXISTS alloc_own ON consumption_allocations;
CREATE POLICY alloc_own ON consumption_allocations FOR SELECT
  USING (is_admin() OR charge_id IN (
    SELECT c.id FROM charges c JOIN sponsors s ON s.id = c.sponsor_id WHERE s.user_id = auth.uid()));

DROP POLICY IF EXISTS completion_own ON completion_events;
CREATE POLICY completion_own ON completion_events FOR SELECT
  USING (is_admin() OR charge_id IN (
    SELECT c.id FROM charges c JOIN sponsors s ON s.id = c.sponsor_id WHERE s.user_id = auth.uid()));

DROP POLICY IF EXISTS settings_read ON dokseo_settings;
CREATE POLICY settings_read ON dokseo_settings FOR SELECT USING (true);
DROP POLICY IF EXISTS settings_admin ON dokseo_settings;
CREATE POLICY settings_admin ON dokseo_settings FOR UPDATE USING (is_admin());


-- ════════════════════════════════════════════════════════════════════
-- 13. 스토리지
-- ════════════════════════════════════════════════════════════════════

-- 인증 사진 — 같은 루틴 참여자끼리 보는 피드용이라 공개 버킷
INSERT INTO storage.buckets (id, name, public)
VALUES ('cert-photos', 'cert-photos', true) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "cert_photos_read" ON storage.objects;
CREATE POLICY "cert_photos_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'cert-photos');
DROP POLICY IF EXISTS "cert_photos_own_insert" ON storage.objects;
CREATE POLICY "cert_photos_own_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'cert-photos' AND (storage.foldername(name))[1] = auth.uid()::text);

-- 영수증 (관리자 전용)
INSERT INTO storage.buckets (id, name, public)
VALUES ('dokseo-receipts', 'dokseo-receipts', false) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "dokseo_receipts_admin" ON storage.objects;
CREATE POLICY "dokseo_receipts_admin" ON storage.objects FOR ALL
  USING (bucket_id = 'dokseo-receipts' AND is_admin())
  WITH CHECK (bucket_id = 'dokseo-receipts' AND is_admin());

-- 책 구매 사진 (청소년이 올리고, 관리자만 열람)
--   ⚠️ 절대 public 으로 바꾸지 말 것. 얼굴을 가려도 배경·의상으로 간접 식별될 수 있어
--   후원자 화면에는 어떤 형태로도 내보내지 않는다.
INSERT INTO storage.buckets (id, name, public)
VALUES ('dokseo-proofs', 'dokseo-proofs', false) ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "dokseo_proofs_own_insert" ON storage.objects;
CREATE POLICY "dokseo_proofs_own_insert" ON storage.objects FOR INSERT
  WITH CHECK (bucket_id = 'dokseo-proofs' AND (storage.foldername(name))[1] = auth.uid()::text);

DROP POLICY IF EXISTS "dokseo_proofs_read" ON storage.objects;
CREATE POLICY "dokseo_proofs_read" ON storage.objects FOR SELECT
  USING (bucket_id = 'dokseo-proofs' AND ((storage.foldername(name))[1] = auth.uid()::text OR is_admin()));
