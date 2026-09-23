-- ────────────────────────────────────────────────────────────────────
-- 47. 신청서의 소속을 프로필로 옮긴다
--
--   끗짱 신청서(kkut_applications.affiliation)에 소속을 이미 받고 있는데
--   프로필로 안 넘어와서, 「청소년 확인」 명단에는 소속이 비어 있었다.
--   같은 걸 두 군데서 따로 보고 있으면 어느 쪽이 맞는지 알 수 없다.
--
--   신청서는 「그때 이렇게 냈다」는 기록으로 그대로 두고,
--   프로필의 school_status 를 「지금의 소속」으로 쓴다.
--   끗짱이 MY 에서 고치면 프로필만 바뀐다 — 신청서는 역사다.
-- ────────────────────────────────────────────────────────────────────

-- ── 1. 승인할 때 같이 옮긴다 ───────────────────────────
CREATE OR REPLACE FUNCTION decide_kkut_application(
  p_user uuid, p_approve boolean, p_reason text DEFAULT NULL, p_adult boolean DEFAULT NULL
) RETURNS void AS $$
DECLARE v_affil text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;
  IF NOT p_approve AND COALESCE(btrim(p_reason), '') = '' THEN
    RAISE EXCEPTION '반려 사유를 적어주세요';
  END IF;

  UPDATE kkut_applications
     SET status        = CASE WHEN p_approve THEN 'approved' ELSE 'rejected' END,
         reject_reason = CASE WHEN p_approve THEN NULL ELSE p_reason END,
         decided_at    = now(), decided_by = auth.uid()
   WHERE user_id = p_user
  RETURNING affiliation INTO v_affil;
  IF NOT FOUND THEN RAISE EXCEPTION '신청서를 찾을 수 없습니다'; END IF;

  IF p_approve THEN
    UPDATE profiles SET can_lead = true,
           -- 지정하지 않으면 지금 역할을 그대로 둔다. 청소년 끗짱은 계속 청소년이다
           role = CASE WHEN p_adult IS NULL THEN role
                       WHEN p_adult THEN 'adult' ELSE 'youth' END,
           -- 본인이 이미 적어 둔 게 있으면 덮지 않는다
           school_status = COALESCE(NULLIF(btrim(school_status), ''), NULLIF(btrim(v_affil), ''))
     WHERE id = p_user;
  ELSE
    UPDATE profiles SET can_lead = false WHERE id = p_user;
    -- 모집 중이던 루틴만 닫는다. 진행 중인 루틴과 아이들 기록은 안 건드린다
    UPDATE routines SET status = 'done'
     WHERE led_by = p_user AND status IN ('pending', 'recruit');
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION decide_kkut_application(uuid, boolean, text, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION decide_kkut_application(uuid, boolean, text, boolean) TO authenticated;

-- ── 2. 이미 승인된 끗짱들도 채운다 ─────────────────────
UPDATE profiles p
   SET school_status = NULLIF(btrim(a.affiliation), '')
  FROM kkut_applications a
 WHERE a.user_id = p.id
   AND a.status = 'approved'
   AND COALESCE(btrim(p.school_status), '') = ''
   AND COALESCE(btrim(a.affiliation), '') <> '';

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT p.name AS 이름, p.can_lead AS 끗짱,
       p.school_status AS 프로필_소속, a.affiliation AS 신청서_소속
  FROM profiles p
  LEFT JOIN kkut_applications a ON a.user_id = p.id
 WHERE p.can_lead
 ORDER BY p.name;
