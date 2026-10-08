-- 한끗독서 마이그레이션 96
-- 후기 탭에 「책 교환 인증」 — 책을 받은 아이들이 남긴 사진과 책을 고른 이유
--
-- 【왜 함수인가】 book_purchases 는 금액·영수증·책방이 한 표에 있어서 남에게 열 수 없다.
--   **공개로 남긴 건의 사진과 이유, 닉네임, 날짜만** 돌려주는 함수를 낸다.
--   영수증(store_receipt_path)·금액·책방·연락처·실명은 이 함수가 읽지도 않는다.
--
-- 【무엇이 나가나】 photo_public 인 건만. 아이가 올릴 때 공개 칸을 고르고(기본 공개),
--   운영진이 관리자 화면에서 「내리기」로 언제든 뺄 수 있다 — 그러면 여기서도 사라진다.
--   사진은 새 흐름이면 proof_photo_url(공개 버킷 cert-photos 의 주소),
--   옛 흐름이면 book_photo_url 이다. 옛 proof_photo_url 은 비공개 버킷의 **경로**라
--   http 로 시작하는 것만 내보낸다 (영수증 사진이 새어 나가지 않게).
--
-- 로그인한 사람만 부를 수 있다.

CREATE OR REPLACE FUNCTION exchange_feed(p_limit int DEFAULT 30)
RETURNS TABLE (id bigint, photo_url text, reason text, nick text, day date) AS $$
  SELECT b.id,
         COALESCE(NULLIF(btrim(b.book_photo_url), ''),
                  CASE WHEN b.proof_photo_url LIKE 'http%' THEN b.proof_photo_url END),
         NULLIF(btrim(COALESCE(b.pick_reason, '')), ''),
         COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '익명'),
         (b.created_at AT TIME ZONE 'Asia/Seoul')::date
    FROM book_purchases b
    LEFT JOIN profiles p ON p.id = b.user_id
   WHERE b.photo_public
     AND b.status <> 'void'
     AND COALESCE(NULLIF(btrim(b.book_photo_url), ''),
                  CASE WHEN b.proof_photo_url LIKE 'http%' THEN b.proof_photo_url END) IS NOT NULL
   ORDER BY b.created_at DESC
   LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 60)
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION exchange_feed(int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION exchange_feed(int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 함수를 실제로 불러 본다. 기대: 공개로 남긴 사진 수만큼 나온다 (아직 없으면 0)
SELECT (SELECT count(*) FROM exchange_feed(60))                                   AS 지금_보이는_인증,
       (SELECT count(*) FROM book_purchases WHERE photo_public AND status <> 'void') AS 공개_건;
