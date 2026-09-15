-- 한끗독서 마이그레이션 05
-- 책 받은 사진을 후원자에게 보여주기
--
-- 【배경】 아이들이 산 책으로 얼굴을 가리고 찍는 방식이라, 얼굴 노출 없이
--   "책이 실제로 아이 손에 갔다"를 보여줄 수 있다. 다만 얼굴을 가려도
--   배경·옷은 남으므로 두 단계를 둔다.
--     ① 아이가 공개에 동의한 사진만 공개 버킷으로 올라간다
--     ② 그중 운영진이 승인(photo_public)한 것만 후원자 화면에 나간다
--   문장(quote_public)과 같은 방식이다.
--
--   정산용 증빙(proof_photo_url, dokseo-proofs)은 지금처럼 비공개로 남는다.
--   ⚠️ dokseo-proofs 버킷은 절대 public 으로 바꾸지 말 것.

ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS book_photo_url text;
ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS photo_public boolean NOT NULL DEFAULT false;

-- 아이가 직접 공개 상태로 넣지 못하게 막는다. 승인은 운영진만
CREATE OR REPLACE FUNCTION check_book_purchase_insert() RETURNS trigger AS $$
DECLARE v_balance int;
BEGIN
  IF is_admin() THEN RETURN NEW; END IF;

  NEW.status       := 'pending';
  NEW.amount       := NULL;
  NEW.receipt_url  := NULL;
  NEW.settled_by   := NULL;
  NEW.settled_at   := NULL;
  NEW.photo_public := false;   -- 노출 여부는 운영진이 정한다

  v_balance := dokseo_balance(NEW.user_id, NEW.routine_id);
  IF v_balance <= 0 THEN
    RAISE EXCEPTION '아직 쓸 수 있는 적립금이 없습니다';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 후원자에게 나가는 사진. user_id 도 책방도 내보내지 않는다
CREATE OR REPLACE FUNCTION dokseo_book_photos(p_limit int DEFAULT 12)
RETURNS TABLE (photo_url text, day date) AS $$
  SELECT book_photo_url, (created_at AT TIME ZONE 'Asia/Seoul')::date
    FROM book_purchases
   WHERE photo_public AND book_photo_url IS NOT NULL AND book_photo_url <> ''
   ORDER BY created_at DESC LIMIT p_limit;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

GRANT EXECUTE ON FUNCTION dokseo_book_photos(int) TO anon, authenticated;
