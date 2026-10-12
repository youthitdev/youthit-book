-- 한끗독서 마이그레이션 123
-- 운영진의 「삭제」 — 끗짱은 신청 기록을, 청소년은 「탈퇴 처리」 (2026-10-12 사용자)
--
-- ── A. 끗짱 신청 삭제 (admin_delete_kkut_app) ──────────────────────
--   끗짱 신청서 한 줄만 지운다. 사람(회원)은 그대로 남는다. 테스트로 들어온 신청이나 잘못 들어온 신청을 치울 때 쓴다.
--   · 승인되어 끗짱 권한이 있는 사람은 지우지 못한다. 먼저 「끗짱 취소」를 한다.
--   · 신청서에 적힌 연락처·소개 같은 개인 내용도 함께 사라진다.
--
-- ── B. 청소년 탈퇴 처리 (admin_withdraw_member) ────────────────────
--   「개인정보는 지우고, 기록은 이름 없이 남긴다」.
--   【지우는 것 — 그 사람을 알아볼 수 있는 것】
--     · 이름·닉네임·지역·재학 상태·프로필 사진·휴대폰 번호·생년월일·서류·알림 설정·푸시 기기·알림함·끗짱 신청서
--     · 그 사람이 쓴 인증 사진·글·문장, 댓글·후기 본문 (자리는 남고 「탈퇴한 회원」 으로 보인다)
--     · 로그인 정보 — 이메일을 비식별로 바꾸고 로그인을 막는다. 같은 이메일로 다시 가입할 수 있다.
--   【남기는 것 — 숫자와 돈의 기록】
--     · 인증 날짜·루틴·쪽수·포인트(인증 횟수), 책 교환·정산 기록, 완독 기록, 좋아요
--     · 이름은 「탈퇴한 회원」 으로 바뀌어 누구인지 알 수 없다. 후원 보고와 책방 정산 숫자는 그대로 맞는다.
--   【막는 것】 운영진 · 끗짱(권한이 있거나 루틴을 맡은 사람) · 정산 대기 중인 교환이 있는 사람.
--   【같이 하는 것】 쓰던 교환권 QR 은 취소하고, 참여 중인 루틴에서 빠진다.
--   결과로 지워야 할 파일(사진·서류) 주소를 돌려준다 — 관리자 화면이 저장소에서 지운다.
--
-- ⚠️ 되돌릴 수 없다. 78·79·103·107 뒤에 돌린다. 여러 번 돌려도 된다 (함수만 만든다).

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS withdrawn_at timestamptz;
COMMENT ON COLUMN profiles.withdrawn_at IS '운영진이 탈퇴 처리한 시각. 있으면 로그인할 수 없고 개인정보는 지워진 상태다';

-- ── A. 끗짱 신청 삭제 ──────────────────────────────────
CREATE OR REPLACE FUNCTION admin_delete_kkut_app(p_user uuid) RETURNS void AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  IF EXISTS (SELECT 1 FROM profiles WHERE id = p_user AND can_lead) THEN
    RAISE EXCEPTION '끗짱 권한이 있는 분이에요. 먼저 「끗짱 취소」를 해 주세요';
  END IF;
  DELETE FROM kkut_applications WHERE user_id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION '지울 신청서가 없어요'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_delete_kkut_app(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_delete_kkut_app(uuid) TO authenticated;

-- ── B. 청소년 탈퇴 처리 ────────────────────────────────
CREATE OR REPLACE FUNCTION admin_withdraw_member(p_user uuid) RETURNS jsonb AS $$
DECLARE
  v_urls  text[] := '{}';
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
  ) x WHERE u IS NOT NULL AND btrim(u) <> '';

  -- 쓰던 교환권은 취소, 참여는 끝낸다
  UPDATE redemptions SET status = 'canceled' WHERE user_id = p_user AND status = 'issued';
  DELETE FROM routine_participants WHERE user_id = p_user;

  -- 그 사람이 쓴 것: 사진·글·문장은 지우고 날짜·쪽수 같은 기록은 남긴다
  UPDATE certifications SET photo_urls = '{}', content = NULL, quote = NULL, quote_public = false
   WHERE user_id = p_user;
  UPDATE cert_comments SET content = '(탈퇴한 회원의 댓글이에요)' WHERE user_id = p_user;
  UPDATE reviews SET content = '(탈퇴한 회원의 후기예요)', is_public = false WHERE user_id = p_user;
  UPDATE routine_books SET cover_url = NULL WHERE user_id = p_user;

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

  RETURN jsonb_build_object('auth', v_auth, 'urls', to_jsonb(v_urls));
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_withdraw_member(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_withdraw_member(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무도 지우지 않는다. 기대: 함수 2 / 칸 1
SELECT (SELECT count(*) FROM pg_proc WHERE proname IN ('admin_delete_kkut_app', 'admin_withdraw_member')) AS 함수_2이어야,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'profiles' AND column_name = 'withdrawn_at')                                 AS 칸_1이어야;
