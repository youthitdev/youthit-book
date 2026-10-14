-- 한끗독서 마이그레이션 126
-- 랜딩 「아이들이 고른 책」 — 운영진이 승인한 책 교환 사진만 보인다 (2026-10-14 사용자)
--
-- 【왜】 랜딩은 로그인 없이 누구나 본다. 얼굴을 가려도 배경·옷이 남으므로 아이가 공개에 동의한 것만으로는 부족하고,
--   운영진이 한 번 눈으로 보고 「랜딩에 올리기」를 누른 사진만 나가야 한다.
--   그런데 랜딩 함수(05)는 옛 칸(book_photo_url)만 읽어서, 앱의 지금 흐름(proof_photo_url)으로 올라온 사진은
--   동의·승인이 어떻든 랜딩에 나오지 않았다.
--
-- 【세 단계】
--   1) 아이가 앱에서 남길 때 공개에 동의 (photo_public) — 앱 안 「책 교환 인증」 목록에는 이때부터 보인다 (96)
--   2) 운영진이 관리자 화면에서 사진을 보고 「랜딩에 올리기」 (landing_ok, 이 파일에서 새로 둔다)
--   3) 랜딩은 2)를 한 것만 보인다. 언제든 「내리기」로 뺄 수 있다
--
-- 【지키는 것】
--   · landing_ok 는 운영진만 바꾼다 (아이가 건을 만들거나 고칠 때 값을 못 넣게 막는다)
--   · 탈퇴 처리한 회원(123)의 사진은 랜딩에서 빠진다
--   · 닉네임·책방·금액은 내보내지 않는다 (사진과 날짜만)
--   · 옛 흐름에서 운영진이 이미 공개해 둔 사진(book_photo_url 이 있고 photo_public)은 승인된 것으로 옮긴다
--
-- ⚠️ 05·96·123 뒤에 돌린다. 여러 번 돌려도 된다.

ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS landing_ok boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN book_purchases.landing_ok IS '운영진이 보고 랜딩(로그인 전 화면)에 올리기로 한 사진. 운영진만 바꾼다';

-- 운영진만 바꾼다. SQL 편집기(auth.uid() 없음)는 통과
CREATE OR REPLACE FUNCTION book_purchases_landing_guard() RETURNS trigger AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    IF TG_OP = 'INSERT' THEN NEW.landing_ok := false;
    ELSE NEW.landing_ok := OLD.landing_ok; END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
DROP TRIGGER IF EXISTS trg_book_purchases_landing_guard ON book_purchases;
CREATE TRIGGER trg_book_purchases_landing_guard
  BEFORE INSERT OR UPDATE ON book_purchases
  FOR EACH ROW EXECUTE FUNCTION book_purchases_landing_guard();

-- 옛 흐름에서 운영진이 이미 공개해 둔 것은 승인된 것으로
UPDATE book_purchases SET landing_ok = true
 WHERE photo_public AND NULLIF(btrim(COALESCE(book_photo_url, '')), '') IS NOT NULL AND NOT landing_ok;

-- 랜딩에 나가는 사진: 운영진이 올린 것만. 사진과 날짜 외에는 내보내지 않는다
CREATE OR REPLACE FUNCTION dokseo_book_photos(p_limit int DEFAULT 12)
RETURNS TABLE (photo_url text, day date) AS $$
  SELECT x.u, x.d FROM (
    SELECT COALESCE(NULLIF(btrim(b.book_photo_url), ''),
                    CASE WHEN b.proof_photo_url LIKE 'http%' THEN b.proof_photo_url END) AS u,
           (b.created_at AT TIME ZONE 'Asia/Seoul')::date AS d,
           b.created_at
      FROM book_purchases b
      JOIN profiles p ON p.id = b.user_id
     WHERE b.landing_ok
       AND (b.photo_public OR NULLIF(btrim(COALESCE(b.book_photo_url, '')), '') IS NOT NULL)
       AND b.status <> 'void'
       AND p.withdrawn_at IS NULL
  ) x
  WHERE x.u IS NOT NULL
  ORDER BY x.created_at DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 12), 1), 24)
$$ LANGUAGE sql SECURITY DEFINER STABLE;
GRANT EXECUTE ON FUNCTION dokseo_book_photos(int) TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 바꾸지 않고 센다. 기대: 칸 1 / 방아쇠 1 / 아래 숫자는 지금 상태
SELECT (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'book_purchases' AND column_name = 'landing_ok')          AS 칸_1이어야,
       (SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_book_purchases_landing_guard') AS 방아쇠_1이어야,
       (SELECT count(*) FROM book_purchases WHERE status <> 'void' AND photo_public)  AS 동의한_사진,
       (SELECT count(*) FROM book_purchases WHERE landing_ok)                         AS 랜딩에_올린_사진,
       (SELECT count(*) FROM dokseo_book_photos(24))                                  AS 랜딩에_지금_나가는_수;
