-- 한끗독서 마이그레이션 121
-- 「끗짱으로 이동」을 누르면 바로 승인하지 않고 끗짱 승인 「대기」로 옮긴다 (2026-10-12 사용자)
--
-- 【왜】 구글폼 심사를 거친 뒤에도, 끗짱 권한은 「끗짱 승인」 탭에서 승인 단추를 눌러야 생기게 한다.
--   청소년 확인 명단의 「끗짱으로 이동」은 그 사람을 끗짱 승인 대기로 올리는 일이다. (바로 세우는 admin_make_kkut(79)은 그대로 있다)
--
-- 【하는 일】 그 사람의 끗짱 신청서를 **대기(pending)** 로 만든다. 그러면 「청소년 확인」 명단에서 빠지고
--   「끗짱 승인」의 심사 대기에 올라온다. 권한(can_lead·role)은 승인하기 전에는 바뀌지 않는다.
--   어른인지 청소년인지는 승인할 때 「끗짱 승인」에서 정한다.
--   이미 신청서가 있는 사람은 오류로 알린다 (끗짱 승인 탭에서 처리).
--
-- ⚠️ 78·79·103 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION admin_make_kkut_pending(
  p_user uuid, p_age int, p_affiliation text, p_why text
) RETURNS void AS $$
DECLARE v_region text; v_contact text; v_name text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  IF p_age IS NULL OR p_age < 14 OR p_age > 100 THEN RAISE EXCEPTION '나이는 14세부터 100세까지 적을 수 있어요'; END IF;
  IF COALESCE(btrim(p_why), '') = '' THEN RAISE EXCEPTION '옮기는 이유를 한 줄 적어주세요'; END IF;
  IF EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p_user) THEN RAISE EXCEPTION '운영진은 옮길 수 없어요'; END IF;

  SELECT name, region INTO v_name, v_region FROM profiles WHERE id = p_user;
  IF v_name IS NULL THEN RAISE EXCEPTION '그런 회원이 없어요'; END IF;
  IF EXISTS (SELECT 1 FROM kkut_applications WHERE user_id = p_user) THEN
    RAISE EXCEPTION '이미 끗짱 신청서가 있어요. 「끗짱 승인」 탭에서 확인해 주세요';
  END IF;

  SELECT phone INTO v_contact FROM profiles_private WHERE id = p_user;

  INSERT INTO kkut_applications
    (user_id, age, affiliation, region, contact, intro, motive, status, applied_at)
  VALUES
    (p_user, p_age,
     COALESCE(NULLIF(btrim(p_affiliation), ''), '없음'),
     COALESCE(NULLIF(btrim(v_region), ''), '미상'),
     COALESCE(NULLIF(btrim(v_contact), ''), '운영진이 따로 확인'),
     btrim(p_why),
     '운영진이 옮겼어요',
     'pending', now());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_make_kkut_pending(uuid, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_make_kkut_pending(uuid, int, text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무도 옮기지 않는다. 기대: 함수 1
SELECT count(*) AS 함수_1이어야 FROM pg_proc WHERE proname = 'admin_make_kkut_pending';
