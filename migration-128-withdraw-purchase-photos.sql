-- 한끗독서 마이그레이션 128
-- 탈퇴 처리가 「책 교환 사진」을 지우지 않던 것을 고친다 (2026-10-14 사용자)
--
-- 【문제】 123 의 탈퇴 처리는 인증 사진·프로필 사진·서류는 지웠지만, 책을 받고 올린 사진(book_purchases 의
--   proof_photo_url·book_photo_url)과 고른 이유(pick_reason)는 그대로 뒀다. 그래서 탈퇴한 회원의 사진이 앱의
--   「책 교환 인증」 목록에 닉네임 없이 남을 수 있었다.
--
-- 【고침】 탈퇴 처리가 아래도 함께 한다.
--   · 그 사진·고른 이유를 비우고, 공개(photo_public)와 랜딩 노출(landing_ok)을 끈다
--   · 저장소에서 지울 파일 주소를 돌려준다 — 새 방식은 공개 저장소의 주소(urls), 옛 방식은 비공개 저장소의 경로(proofs).
--     관리자 화면이 둘 다 저장소에서 지운다
--   · 교환·정산 기록(날짜·책방·금액·영수증)은 그대로 남는다 — 후원 보고와 책방 정산이 맞아야 해서
--
-- 【이미 탈퇴 처리한 회원】 이 파일은 그 사람들의 책 교환 사진을 **앱에서 보이지 않게만** 한다 (공개를 끈다).
--   주소를 이미 비운 뒤가 아니라 아직 남아 있으니 파일 자체는 남는다. 맨 아래 확인 표의 「아직 남은 파일」이 0 이 아니면
--   저장소에서 직접 지워야 한다 (대부분 시험 계정일 것이다).
--
-- ⚠️ 123·126 뒤에 돌린다. 여러 번 돌려도 된다 (함수를 123 판에서 이 판으로 바꾼다).

ALTER TABLE book_purchases ADD COLUMN IF NOT EXISTS landing_ok boolean NOT NULL DEFAULT false;   -- 126 을 돌렸으면 이미 있다

CREATE OR REPLACE FUNCTION admin_withdraw_member(p_user uuid) RETURNS jsonb AS $$
DECLARE
  v_urls  text[] := '{}';
  v_proofs text[] := '{}';   -- 비공개 저장소(dokseo-proofs)에 경로로 들어 있는 책 받은 사진
  v_auth  boolean := false;
  v_new   text := 'withdrawn-' || p_user::text || '@withdrawn.invalid';
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  IF EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p_user) THEN RAISE EXCEPTION '운영진은 탈퇴 처리할 수 없어요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_user) THEN RAISE EXCEPTION '그런 회원이 없어요'; END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE id = p_user AND withdrawn_at IS NOT NULL) THEN RAISE EXCEPTION '이미 탈퇴 처리한 회원이에요'; END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE id = p_user AND can_lead)
     OR EXISTS (SELECT 1 FROM routines WHERE led_by = p_user AND status IN ('pending', 'recruit', 'active')) THEN
    RAISE EXCEPTION '끗짱이거나 맡은 루틴이 있는 분이에요. 먼저 끗짱을 취소하고 루틴을 정리해 주세요';
  END IF;
  IF EXISTS (SELECT 1 FROM book_purchases WHERE user_id = p_user AND status = 'pending') THEN
    RAISE EXCEPTION '정산 대기 중인 책 교환이 있어요. 정산을 마친 뒤에 처리해 주세요';
  END IF;

  -- 지울 파일 주소를 먼저 모은다 (칸을 비우고 나면 알 수 없다)
  SELECT COALESCE(array_agg(u), '{}') INTO v_urls FROM (
    SELECT unnest(photo_urls) AS u FROM certifications WHERE user_id = p_user AND photo_urls IS NOT NULL
    UNION ALL SELECT avatar_url FROM profiles WHERE id = p_user AND avatar_url IS NOT NULL
    UNION ALL SELECT verify_doc_path FROM profiles WHERE id = p_user AND verify_doc_path IS NOT NULL
    UNION ALL SELECT cover_url FROM routine_books WHERE user_id = p_user AND cover_url IS NOT NULL
    UNION ALL SELECT book_photo_url FROM routine_participants WHERE user_id = p_user AND book_photo_url IS NOT NULL
    -- 책 교환 때 올린 사진 (공개 저장소의 주소). 옛 방식의 공개본도 같이
    UNION ALL SELECT book_photo_url  FROM book_purchases WHERE user_id = p_user AND book_photo_url  IS NOT NULL
    UNION ALL SELECT proof_photo_url FROM book_purchases WHERE user_id = p_user AND proof_photo_url LIKE 'http%'
  ) x WHERE u IS NOT NULL AND btrim(u) <> '';
  -- 옛 방식의 책 받은 사진은 비공개 저장소에 주소가 아니라 경로로 들어 있다
  SELECT COALESCE(array_agg(proof_photo_url), '{}') INTO v_proofs FROM book_purchases
   WHERE user_id = p_user AND proof_photo_url IS NOT NULL AND btrim(proof_photo_url) <> '' AND proof_photo_url NOT LIKE 'http%';

  -- 쓰던 교환권은 취소, 참여는 끝낸다
  UPDATE redemptions SET status = 'canceled' WHERE user_id = p_user AND status = 'issued';
  DELETE FROM routine_participants WHERE user_id = p_user;

  -- 그 사람이 쓴 것: 사진·글·문장은 지우고 날짜·쪽수 같은 기록은 남긴다
  UPDATE certifications SET photo_urls = '{}', content = NULL, quote = NULL, quote_public = false
   WHERE user_id = p_user;
  UPDATE cert_comments SET content = '(탈퇴한 회원의 댓글이에요)' WHERE user_id = p_user;
  UPDATE reviews SET content = '(탈퇴한 회원의 후기예요)', is_public = false WHERE user_id = p_user;
  UPDATE routine_books SET cover_url = NULL WHERE user_id = p_user;
  -- 책 교환 때 올린 사진과 「왜 이 책을 골랐는지」. 앱의 책 교환 인증·랜딩에서도 함께 사라진다
  --   (교환·정산 기록 — 날짜·책방·금액·영수증 — 은 그대로 남는다)
  UPDATE book_purchases
     SET book_photo_url = NULL, proof_photo_url = NULL, pick_reason = NULL,
         photo_public = false, landing_ok = false
   WHERE user_id = p_user;

  -- 신청서·알림·푸시
  DELETE FROM kkut_applications WHERE user_id = p_user;
  DELETE FROM notifications     WHERE user_id = p_user;
  DELETE FROM push_subscriptions WHERE user_id = p_user;

  -- 프로필·개인 정보
  UPDATE profiles
     SET name = '탈퇴한 회원', nick = NULL, region = NULL, school_status = NULL, avatar_url = NULL,
         verify_doc_path = NULL, verify_reason = NULL, marketing_ok = false, mute_kinds = '{}',
         withdrawn_at = now()
   WHERE id = p_user;
  UPDATE profiles_private SET phone = NULL, birth_date = NULL WHERE id = p_user;

  -- 로그인 막기. 이메일은 비식별로 바꿔 같은 이메일로 다시 가입할 수 있게 한다.
  -- 이 권한이 없는 프로젝트에서도 나머지 처리는 끝나게 안쪽 블록에 가둔다 (그때는 결과의 auth 가 false)
  BEGIN
    UPDATE auth.users
       SET email = v_new, phone = NULL, encrypted_password = '', raw_user_meta_data = '{}'::jsonb,
           banned_until = 'infinity'
     WHERE id = p_user;
    DELETE FROM auth.identities WHERE user_id = p_user;
    v_auth := true;
  EXCEPTION WHEN OTHERS THEN
    v_auth := false;
  END;

  RETURN jsonb_build_object('auth', v_auth, 'urls', to_jsonb(v_urls), 'proofs', to_jsonb(v_proofs));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_withdraw_member(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_withdraw_member(uuid) TO authenticated;

-- 이미 탈퇴 처리한 회원의 책 교환 사진은 앱·랜딩에서 보이지 않게 한다
UPDATE book_purchases b SET photo_public = false, landing_ok = false
  FROM profiles p
 WHERE p.id = b.user_id AND p.withdrawn_at IS NOT NULL AND (b.photo_public OR b.landing_ok);

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무도 지우지 않는다. 기대: 함수가 새 판 1 / 탈퇴 회원의 공개 사진 0 / 아직 남은 파일은 0 이어야 좋다 (아니면 저장소에서 직접)
SELECT CASE WHEN pg_get_functiondef((SELECT oid FROM pg_proc WHERE proname = 'admin_withdraw_member'))
                 LIKE '%v_proofs%' THEN 1 ELSE 0 END                                                      AS 새_판_1이어야,
       (SELECT count(*) FROM book_purchases b JOIN profiles p ON p.id = b.user_id
         WHERE p.withdrawn_at IS NOT NULL AND (b.photo_public OR b.landing_ok))                           AS 공개_사진_0이어야,
       (SELECT count(*) FROM book_purchases b JOIN profiles p ON p.id = b.user_id
         WHERE p.withdrawn_at IS NOT NULL
           AND (NULLIF(btrim(COALESCE(b.book_photo_url, '')), '') IS NOT NULL
             OR NULLIF(btrim(COALESCE(b.proof_photo_url, '')), '') IS NOT NULL))                          AS 아직_남은_파일;
