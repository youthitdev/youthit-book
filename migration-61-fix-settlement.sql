-- 한끗독서 마이그레이션 61
-- 정산을 바로잡는다 — 고치기와 취소
--
-- 【지금 비어 있던 것】 한 번 정산하면 금액도 책방도 못 고쳤고, 잘못 넣은 건을
--   물릴 길도 없었다. 실제로 테스트 건이 루틴 삭제를 막아서 SQL 을 써야 했다.
--
-- 【지우지 않고 취소한다】 기부금 사용명세는 「무엇을 썼나」뿐 아니라
--   「왜 이 숫자가 됐나」를 설명해야 한다. 줄이 사라지면 설명할 게 없다.
--   status 에 'void' 가 처음부터 있고 앱도 이미 void 를 빼고 센다 —
--   관리자 화면에만 길이 없었다.
--
-- 【⚠️ 돈을 되돌려 놓아야 한다】 정산은 consumption_allocations 로 후원금을
--   차감한다. 그냥 void 로만 바꾸면 charges.remaining_amount 가 줄어든 채로
--   남아 기금 잔액이 영영 틀어진다. 반드시 배분을 되돌린다.
--
-- 【입금까지 끝난 건은 못 건드린다】 책방에 돈이 이미 나갔다. 그건 취소가
--   아니라 환입이라 회계가 다르다. 사람이 책방과 이야기해야 한다.

-- ── 배분 되돌리기 (내부용) ─────────────────────────────
CREATE OR REPLACE FUNCTION unallocate_purchase(p_id bigint) RETURNS void AS $$
DECLARE a record;
BEGIN
  FOR a IN SELECT charge_id, amount FROM consumption_allocations WHERE purchase_id = p_id LOOP
    UPDATE charges
       SET remaining_amount = remaining_amount + a.amount,
           status       = 'active',
           completed_at = NULL
     WHERE id = a.charge_id;
    -- 다 쓴 걸로 보고 만들어 둔 완료 카드를 거둔다
    DELETE FROM completion_events WHERE charge_id = a.charge_id;
  END LOOP;
  DELETE FROM consumption_allocations WHERE purchase_id = p_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 배분하기 (내부용) ──────────────────────────────────
-- settle_book_purchase 안의 고리와 같은 일을 한다. 고칠 때 둘 다 봐야 한다
CREATE OR REPLACE FUNCTION allocate_purchase(p_id bigint, p_amount int) RETURNS void AS $$
DECLARE v_left int := p_amount; v_take int; v_charge record; v_pool int;
BEGIN
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
    VALUES (p_id, v_charge.id, v_take);

    UPDATE charges
       SET remaining_amount = remaining_amount - v_take,
           status       = CASE WHEN remaining_amount - v_take = 0 THEN 'completed' ELSE status END,
           completed_at = CASE WHEN remaining_amount - v_take = 0 THEN now() ELSE completed_at END
     WHERE id = v_charge.id;

    v_left := v_left - v_take;
  END LOOP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION unallocate_purchase(bigint) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION allocate_purchase(bigint, int) FROM PUBLIC, anon, authenticated;

-- ── 정산 고치기 ────────────────────────────────────────
CREATE OR REPLACE FUNCTION fix_book_purchase(
  p_purchase_id bigint,
  p_amount      int    DEFAULT NULL,   -- NULL 이면 금액은 그대로
  p_bookstore   bigint DEFAULT NULL,
  p_note        text   DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE g record; v_user uuid; v_routine bigint; v_balance int; v_amt int;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;

  SELECT * INTO g FROM book_purchases WHERE id = p_purchase_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 건이 없습니다 (id=%)', p_purchase_id; END IF;
  IF g.status <> 'settled' THEN RAISE EXCEPTION '정산이 끝난 건만 고칠 수 있습니다'; END IF;
  IF g.paid_at IS NOT NULL THEN
    RAISE EXCEPTION '이미 책방에 입금한 건이라 고칠 수 없습니다. 책방과 먼저 이야기해 주세요';
  END IF;

  v_amt := COALESCE(p_amount, g.amount);
  IF v_amt <= 0 THEN RAISE EXCEPTION '금액이 올바르지 않습니다'; END IF;

  -- 금액이 바뀌면 배분을 다시 한다
  IF v_amt <> g.amount THEN
    v_balance := dokseo_balance(g.user_id, g.routine_id) + g.amount;   -- 이 건을 뺀 잔액
    IF v_amt > v_balance THEN
      RAISE EXCEPTION '적립금 잔액을 넘습니다 (쓸 수 있는 돈 %원 / 입력 %원)', v_balance, v_amt;
    END IF;
    PERFORM unallocate_purchase(p_purchase_id);
    PERFORM allocate_purchase(p_purchase_id, v_amt);
  END IF;

  UPDATE book_purchases
     SET amount       = v_amt,
         bookstore_id = COALESCE(p_bookstore, bookstore_id),
         note         = COALESCE(NULLIF(btrim(p_note), ''), note)
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('id', p_purchase_id, 'amount', v_amt);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ── 정산 취소 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION void_book_purchase(
  p_purchase_id bigint,
  p_reason      text
) RETURNS jsonb AS $$
DECLARE g record;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '정산 권한이 없습니다'; END IF;
  IF COALESCE(btrim(p_reason), '') = '' THEN RAISE EXCEPTION '취소 사유를 적어주세요'; END IF;

  SELECT * INTO g FROM book_purchases WHERE id = p_purchase_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 건이 없습니다 (id=%)', p_purchase_id; END IF;
  IF g.status = 'void' THEN RAISE EXCEPTION '이미 취소된 건입니다'; END IF;
  IF g.paid_at IS NOT NULL THEN
    RAISE EXCEPTION '이미 책방에 입금한 건이라 취소할 수 없습니다. 책방과 먼저 이야기해 주세요';
  END IF;

  -- 정산된 건이었으면 후원금을 되돌려 놓는다
  IF g.status = 'settled' THEN
    PERFORM unallocate_purchase(p_purchase_id);
  END IF;

  UPDATE book_purchases
     SET status = 'void',
         note   = COALESCE(NULLIF(btrim(note), '') || E'\n', '') || '[취소] ' || btrim(p_reason)
   WHERE id = p_purchase_id;

  RETURN jsonb_build_object('id', p_purchase_id, 'status', 'void');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION fix_book_purchase(bigint, int, bigint, text)  FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION fix_book_purchase(bigint, int, bigint, text)  TO authenticated;
REVOKE EXECUTE ON FUNCTION void_book_purchase(bigint, text)              FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION void_book_purchase(bigint, text)              TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT p.proname AS 함수, p.prosecdef AS 정의자권한,
       pg_get_function_identity_arguments(p.oid) AS 인자
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('fix_book_purchase','void_book_purchase','unallocate_purchase','allocate_purchase')
 ORDER BY 1;
