-- ────────────────────────────────────────────────────────────────────
-- 46. 확인을 되돌릴 수 있게
--
--   승인하면 끝이었다. 잘못 눌렀거나, 나중에 사실이 달랐던 걸 알게 되면
--   되돌릴 길이 없었다.
--
--   decide_verify(user, false, ...) 는 원래도 돌아갔는데, 되돌릴 때
--   verified_at 과 verify_kind 를 안 지워서 「대면 확인으로 확인」이
--   그대로 남았다. 취소했는데 확인했다고 적혀 있는 화면이 된다.
--
--   되돌리면 확인 기록도 같이 지운다. 「언제 무엇으로 확인했다」가
--   사실이 아니게 됐으니까.
--
--   ⚠️ 이미 받아 간 책은 건드리지 않는다 (book_purchases 는 그대로).
--      막히는 건 앞으로의 루틴 참여와 책 받기다.
-- ────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION decide_verify(
  p_user uuid, p_approve boolean, p_kind text DEFAULT NULL, p_reason text DEFAULT NULL
) RETURNS void AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;
  IF NOT p_approve AND COALESCE(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION '사유를 적어주세요';
  END IF;

  IF p_approve THEN
    -- 파일 경로를 지운다. 실제 파일은 화면에서 지운 뒤 이걸 부른다
    UPDATE profiles
       SET verify_status = 'approved', verified_at = now(),
           verify_kind = COALESCE(btrim(p_kind), verify_kind, '확인함'),
           verify_doc_path = NULL, verify_reason = NULL
     WHERE id = p_user;
  ELSE
    UPDATE profiles
       SET verify_status = 'rejected', verify_reason = btrim(p_reason),
           verify_doc_path = NULL,
           -- 되돌리면 확인 기록도 지운다. 안 지우면 「취소됨」 옆에
           -- 「대면 확인으로 확인」이 나란히 남는다
           verified_at = NULL, verify_kind = NULL
     WHERE id = p_user;
  END IF;
  IF NOT FOUND THEN RAISE EXCEPTION '사람을 찾을 수 없습니다'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION decide_verify(uuid, boolean, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION decide_verify(uuid, boolean, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (prosrc LIKE '%verified_at = NULL%') AS 되돌릴때_기록도지움
  FROM pg_proc WHERE proname = 'decide_verify';
