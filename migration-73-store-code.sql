-- 한끗독서 마이그레이션 73
-- 책방이 그 자리에서 번호를 눌러 확인한다
--
-- 【무엇을 고치나】 「책 받았어요」는 책방을 목록에서 고르게 했다. 비슷한
--   이름을 잘못 고르면 정산 때 돈이 엉뚱한 책방으로 간다. 이게 제일 위험했다.
--
-- 【왜 아이가 아니라 책방이 누르나】 번호가 아이를 거치면 언젠가 아이들끼리
--   돈다. 그러면 번호가 아무 뜻도 없어진다. 책방이 직접 누르면 그건 조회가
--   아니라 서명이다 — 「이 아이에게 이 책을 줬습니다」가 그 자리에 남는다.
--
-- 【막지는 않는다】 주인이 자리에 없거나 알바생이 번호를 모를 수 있다.
--   그래도 아이는 책을 받았다. 번호 없이도 기록은 되고, 운영진 화면에
--   「번호 없이」로 뜬다. 어차피 영수증과 맞춰 보는 일이라 위험은 없고,
--   아이가 묶이지 않는다.
--
-- 【왜 bookstores 에 칸을 안 더하나】 거기 두면 로그인한 사람은 누구나
--   읽는다. 칸 단위로 권한을 빼면 이번엔 운영진의 select * 까지 막힌다.
--   표를 따로 두고 운영진에게만 연다.

-- ── 1. 번호는 따로 둔다 ────────────────────────────────
CREATE TABLE IF NOT EXISTS bookstore_codes (
  bookstore_id bigint PRIMARY KEY REFERENCES bookstores(id) ON DELETE CASCADE,
  code         char(4) NOT NULL UNIQUE,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE bookstore_codes IS '책방이 그 자리에서 누르는 확인 번호. 운영진만 본다';

ALTER TABLE bookstore_codes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bc_admin ON bookstore_codes;
CREATE POLICY bc_admin ON bookstore_codes FOR ALL TO authenticated
  USING (is_admin()) WITH CHECK (is_admin());

-- 아직 번호가 없는 책방에 하나씩 쥐여 준다. 0 으로 시작하는 번호는 빼고
DO $$
DECLARE r record; c char(4);
BEGIN
  FOR r IN SELECT b.id FROM bookstores b
            WHERE NOT EXISTS (SELECT 1 FROM bookstore_codes k WHERE k.bookstore_id = b.id) LOOP
    LOOP
      c := lpad((1000 + floor(random() * 9000))::int::text, 4, '0');
      EXIT WHEN NOT EXISTS (SELECT 1 FROM bookstore_codes WHERE code = c);
    END LOOP;
    INSERT INTO bookstore_codes (bookstore_id, code) VALUES (r.id, c);
  END LOOP;
END $$;

-- ── 2. 번호를 눌렀는지 ────────────────────────────────
ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS code_ok boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN book_purchases.code_ok IS '책방이 그 자리에서 번호를 눌렀는지';

-- ── 3. 번호로 책방 이름만 돌려준다 ─────────────────────
-- 사장님이 누르고 나서 「맞게 들어갔나」를 그 자리에서 알아야 한다.
-- 맞는 번호 하나에 이름 하나만 나간다 — 목록이 새지 않는다
CREATE OR REPLACE FUNCTION bookstore_by_code(p_code text)
RETURNS TABLE(id bigint, name text, region text) AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  RETURN QUERY
    SELECT b.id, b.name, b.region
      FROM bookstore_codes k JOIN bookstores b ON b.id = k.bookstore_id
     WHERE k.code = btrim(p_code) AND b.active
     LIMIT 1;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

REVOKE EXECUTE ON FUNCTION bookstore_by_code(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION bookstore_by_code(text) TO authenticated;

-- ── 4. 기록은 이 문으로만 ──────────────────────────────
-- 아이가 직접 INSERT 하면 code_ok 를 제 손으로 켤 수 있다. 문을 하나로 좁힌다
DROP POLICY IF EXISTS book_purchases_own_insert ON book_purchases;

CREATE OR REPLACE FUNCTION redeem_voucher(
  p_routine_id bigint,
  p_code       text   DEFAULT NULL,
  p_store_id   bigint DEFAULT NULL,
  p_proof      text   DEFAULT NULL,
  p_public     text   DEFAULT NULL
) RETURNS jsonb AS $$
DECLARE v_store bigint; v_name text; v_ok boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;

  IF COALESCE(btrim(p_code), '') <> '' THEN
    SELECT b.id, b.name INTO v_store, v_name
      FROM bookstore_codes k JOIN bookstores b ON b.id = k.bookstore_id
     WHERE k.code = btrim(p_code) AND b.active;
    IF v_store IS NULL THEN RAISE EXCEPTION '그런 번호가 없어요'; END IF;
    v_ok := true;
  ELSE
    SELECT b.id, b.name INTO v_store, v_name
      FROM bookstores b WHERE b.id = p_store_id AND b.active;
    IF v_store IS NULL THEN RAISE EXCEPTION '책방을 골라주세요'; END IF;
  END IF;

  -- 청소년인지, 공유회를 다녀왔는지는 check_purchase_verified 가 본다.
  -- 여기서는 책방만 가린다
  INSERT INTO book_purchases (user_id, routine_id, bookstore_id,
                              proof_photo_url, book_photo_url, code_ok)
  VALUES (auth.uid(), p_routine_id, v_store, p_proof, p_public, v_ok);

  RETURN jsonb_build_object('bookstore_id', v_store, 'bookstore', v_name, 'code_ok', v_ok);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION redeem_voucher(bigint, text, bigint, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION redeem_voucher(bigint, text, bigint, text, text) TO authenticated;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM bookstores)                                   AS 책방수,
       (SELECT count(*) FROM bookstore_codes)                              AS 번호발급,
       (SELECT count(DISTINCT code) FROM bookstore_codes)                  AS 서로다름,
       (SELECT count(*) FROM pg_proc WHERE proname = 'bookstore_by_code')  AS 조회함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'redeem_voucher')     AS 기록함수,
       (SELECT count(*) FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
         WHERE c.relname = 'book_purchases'
           AND p.polname = 'book_purchases_own_insert')                    AS 옛문_남음;
