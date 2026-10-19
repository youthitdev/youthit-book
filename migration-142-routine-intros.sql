-- 한끗독서 마이그레이션 142
-- 루틴의 「첫 인증」에 자기소개(사진 + 한 줄)를 남기게 한다 (2026-10-19 사용자)
--
-- 【왜】 온라인으로 하는 활동이라 서로를 알 계기가 없다. 첫 인증을 올릴 때 「요즘 내가 관심 있는 것」 사진과 한 줄 소개를
--   먼저 남기게 하고, 같은 루틴 친구들이 「함께 읽는 친구들」에서 본다. 루틴마다 새로 받는다 (루틴이 바뀌면 새 친구들이다).
--
-- 【무엇을】
--   1. routine_intros 표: 루틴마다·사람마다 한 건. 글(200자 이내)과 사진 주소. 끗짱·운영진이 부적절하면 내린다(hidden).
--      표를 직접 읽는 것은 본인·그 루틴의 끗짱·운영진뿐이다. 다른 친구들은 아래 routine_members 로만 본다.
--   2. routine_members(): 「함께 읽는 친구들」 목록에 소개 글·사진·소개 번호를 함께 돌려준다 (내린 소개는 뺀다).
--   3. 탈퇴 처리: 자기소개 글과 사진 파일도 함께 지운다 (128 판에 이 두 줄을 더했다).
--
-- 【이 파일을 돌리기 전에는】 앱이 이 표를 읽지 못하면 자기소개 단계를 보이지 않는다. 그대로 인증할 수 있다.
-- 【서버는 필수로 막지 않는다】 「첫 인증에 필수」는 앱 화면에서 지킨다. 서버까지 막으면 앱이 옛 판으로 열려 있는 아이의 인증이 막힌다.
--
-- ⚠️ 78(admin_user_ids)·129·130·128 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE TABLE IF NOT EXISTS routine_intros (
  id         bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  routine_id bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  user_id    uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  body       text   NOT NULL CHECK (char_length(btrim(body)) BETWEEN 1 AND 200),
  photo_url  text   NOT NULL,
  hidden     boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (routine_id, user_id)
);
ALTER TABLE routine_intros ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS intros_read   ON routine_intros;
DROP POLICY IF EXISTS intros_insert ON routine_intros;
DROP POLICY IF EXISTS intros_manage ON routine_intros;
DROP POLICY IF EXISTS intros_delete ON routine_intros;
CREATE POLICY intros_read ON routine_intros FOR SELECT
  USING (user_id = auth.uid() OR is_admin()
         OR routine_id IN (SELECT id FROM routines WHERE led_by = auth.uid()));
-- 내 소개는 내가, 그 루틴에 참여한 사람만 남긴다
CREATE POLICY intros_insert ON routine_intros FOR INSERT
  WITH CHECK (user_id = auth.uid()
              AND EXISTS (SELECT 1 FROM routine_participants rp
                           WHERE rp.routine_id = routine_intros.routine_id AND rp.user_id = auth.uid() AND rp.status = 'approved'));
-- 부적절하면 끗짱·운영진이 내린다 (hidden). 본인은 고치지 못한다
CREATE POLICY intros_manage ON routine_intros FOR UPDATE
  USING (is_admin() OR routine_id IN (SELECT id FROM routines WHERE led_by = auth.uid()))
  WITH CHECK (is_admin() OR routine_id IN (SELECT id FROM routines WHERE led_by = auth.uid()));
CREATE POLICY intros_delete ON routine_intros FOR DELETE
  USING (is_admin() OR routine_id IN (SELECT id FROM routines WHERE led_by = auth.uid()));

-- ── 「함께 읽는 친구들」에 소개를 함께 ───────────────────
-- 돌려주는 칸이 늘어서 먼저 지우고 다시 만든다 (같은 이름으로 칸만 다른 함수를 두면 안 된다)
DROP FUNCTION IF EXISTS routine_members(bigint);
CREATE FUNCTION routine_members(p_routine bigint)
RETURNS TABLE (nick text, books jsonb, intro_id bigint, intro_body text, intro_photo text) AS $$
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), '친구'),
         COALESCE((SELECT jsonb_agg(jsonb_build_object('t', b.title,
                                      'c', COALESCE(NULLIF(btrim(bc.cover_url), ''), NULLIF(btrim(COALESCE(b.found_cover_url, '')), '')))
                                    ORDER BY b.created_at)
                     FROM routine_books b
                     LEFT JOIN book_covers bc ON bc.k = book_key(b.title)
                    WHERE b.routine_id = rp.routine_id AND b.user_id = rp.user_id), '[]'::jsonb),
         ri.id, ri.body, ri.photo_url
    FROM routine_participants rp
    JOIN routines r ON r.id = rp.routine_id
    JOIN profiles p ON p.id = rp.user_id
    LEFT JOIN routine_intros ri ON ri.routine_id = rp.routine_id AND ri.user_id = rp.user_id AND NOT ri.hidden
   WHERE rp.routine_id = p_routine
     AND rp.status = 'approved'
     AND r.status IN ('recruit', 'active')
     AND p.withdrawn_at IS NULL
     AND COALESCE(p.role, 'youth') = 'youth'
     AND NOT COALESCE(p.can_lead, false)
     AND ( auth.uid() IS NULL
           OR is_admin()
           OR EXISTS (SELECT 1 FROM profiles me
                       WHERE me.id = auth.uid() AND me.withdrawn_at IS NULL
                         AND (me.verify_status = 'approved' OR me.can_lead)) )
   ORDER BY rp.joined_at
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION routine_members(bigint) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION routine_members(bigint) TO authenticated;

-- ── 탈퇴 처리: 자기소개도 지운다 ───────────────────────
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
    -- 첫 인증 때 올린 자기소개 사진 (142)
    UNION ALL SELECT photo_url FROM routine_intros WHERE user_id = p_user AND photo_url IS NOT NULL
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
  DELETE FROM routine_intros       WHERE user_id = p_user;   -- 자기소개 글·사진 (142)

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

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 표 1 · 정책 4 · 함수가 새 판(소개 칸이 있는 판) 1 · 탈퇴 함수가 새 판 1
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_name = 'routine_intros')                AS 표_1이어야,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'routine_intros')                               AS 정책_4여야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'routine_members' AND pg_get_function_result(oid) LIKE '%intro_body%') AS 소개_함수_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'admin_withdraw_member' AND prosrc LIKE '%routine_intros%') AS 탈퇴_함수_1이어야;
