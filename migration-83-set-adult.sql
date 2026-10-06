-- 한끗독서 마이그레이션 83
-- 어른인지 청소년인지를 나중에도 고친다
--
-- 【무엇이 막혀 있었나】 역할은 끗짱을 승인하거나 세우는 그 순간에만 정해졌다.
--   그때 잘못 고르면 되돌릴 길이 없었다 — 끗짱이 된 뒤에는 화면에 「끗짱 취소」만
--   남는다. 실제로 43세 끗짱이 청소년인 채로 남았다.
--
-- 【왜 admin_make_kkut 을 다시 쓰지 않나】 그 함수는 신청서를 만들고 승인하고
--   본인에게 알림까지 보낸다. 역할 한 칸 고치자고 「끗짱이 되었어요」가 또 가면
--   안 된다. 하는 일이 다르면 함수도 달라야 한다.
--
-- ⚠️ 이 칸이 돈의 문이다. role='youth' 여야 교환권·책이 나간다
--   (check_purchase_verified). 어른으로 바꾸면 그 사람은 책을 못 받고,
--   청소년으로 바꾸면 받을 수 있게 된다. 운영진만 만질 수 있는 이유다.

CREATE OR REPLACE FUNCTION admin_set_adult(p_user uuid, p_adult boolean)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;
  IF p_adult IS NULL THEN RAISE EXCEPTION '어른인지 청소년인지 골라주세요'; END IF;

  UPDATE profiles
     SET role = CASE WHEN p_adult THEN 'adult' ELSE 'youth' END
   WHERE id = p_user;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 회원이 없어요'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE EXECUTE ON FUNCTION admin_set_adult(uuid, boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_set_adult(uuid, boolean) TO authenticated;

-- ── 제대로 붙었는지 ────────────────────────────────────
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'admin_set_adult')              AS 바꾸기함수,
       (SELECT has_function_privilege('anon','admin_set_adult(uuid, boolean)','EXECUTE')) AS 익명도되나,
       (SELECT count(*) FROM profiles WHERE can_lead AND COALESCE(role,'youth') <> 'adult')
                                                                                     AS 청소년인_끗짱;
