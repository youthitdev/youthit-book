-- 한끗독서 마이그레이션 79
-- 운영진이 끗짱을 직접 세운다
--
-- 【왜 필요한가】 지금 끗짱이 되는 길은 하나뿐이다 — 본인이 앱에서 신청서를
--   쓰고 운영진이 승인한다. 그런데 유스보이스가 직접 섭외한 어른 끗짱에게
--   「앱 깔고 MY 들어가서 지원동기 써 주세요」는 과하다. 이미 통화로 다
--   확인한 분들이다.
--
-- 【그래도 신청서는 만든다】 끗짱은 청소년들의 기록을 다 보는 권한이다.
--   「누구를, 왜 세웠나」가 안 남으면 나중에 아무도 설명할 수 없다.
--   그래서 이 함수는 신청서를 지우는 게 아니라, 운영진이 대신 쓰고
--   그 자리에서 승인한 것으로 남긴다 — 끗짱 승인 탭에 그대로 보인다.
--
-- 【이미 신청서를 낸 사람이면】 본인이 쓴 소개·동기는 건드리지 않고
--   상태만 승인으로 바꾼다. 사람이 쓴 글을 운영진 메모로 덮으면 안 된다.

CREATE OR REPLACE FUNCTION admin_make_kkut(
  p_user        uuid,
  p_adult       boolean,
  p_age         int,
  p_affiliation text,
  p_why         text
) RETURNS void AS $$
DECLARE v_region text; v_contact text; v_name text;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;
  IF p_age IS NULL OR p_age < 14 OR p_age > 100 THEN
    RAISE EXCEPTION '나이는 14세부터 100세까지 적을 수 있어요';
  END IF;
  IF COALESCE(btrim(p_why), '') = '' THEN
    RAISE EXCEPTION '왜 세우는지 한 줄 적어주세요';
  END IF;

  SELECT name, region INTO v_name, v_region FROM profiles WHERE id = p_user;
  IF v_name IS NULL THEN RAISE EXCEPTION '그런 회원이 없어요'; END IF;

  -- 연락처는 운영진만 보는 표에 있다. 없으면 없는 대로 적는다
  SELECT phone INTO v_contact FROM profiles_private WHERE id = p_user;

  INSERT INTO kkut_applications
    (user_id, age, affiliation, region, contact, intro, motive,
     status, reject_reason, applied_at, decided_at, decided_by)
  VALUES
    (p_user, p_age,
     COALESCE(NULLIF(btrim(p_affiliation), ''), '없음'),
     COALESCE(NULLIF(btrim(v_region), ''), '미상'),
     COALESCE(NULLIF(btrim(v_contact), ''), '운영진이 따로 확인'),
     btrim(p_why),
     '운영진이 직접 세운 끗짱이에요',
     'approved', NULL, now(), now(), auth.uid())
  ON CONFLICT (user_id) DO UPDATE
    SET status = 'approved', reject_reason = NULL,
        decided_at = now(), decided_by = auth.uid();
        -- 본인이 쓴 소개·동기는 덮지 않는다

  UPDATE profiles
     SET can_lead = true,
         role = CASE WHEN p_adult THEN 'adult' ELSE 'youth' END
   WHERE id = p_user;

  -- 권한이 갑자기 생겼는데 본인만 모르면 안 된다
  PERFORM notify_push(p_user, '끗짱이 되었어요 🌱',
    '이제 루틴을 만들고 함께 읽을 사람을 모을 수 있어요',
    '/youthit-book/app.html');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION admin_make_kkut(uuid, boolean, int, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_make_kkut(uuid, boolean, int, text, text) TO authenticated;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'admin_make_kkut')          AS 세우기함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'decide_kkut_application')  AS 승인함수,
       (SELECT has_function_privilege('anon',
          'admin_make_kkut(uuid, boolean, int, text, text)', 'EXECUTE'))         AS 익명도되나;
