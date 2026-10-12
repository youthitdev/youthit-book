-- 한끗독서 마이그레이션 122
-- 반려한 끗짱 신청을 「재심사」로 심사 대기에 다시 올린다 (2026-10-12 사용자)
--
-- 【왜】 반려는 「결정한 기록」이라 「지난 심사」에 둔다. 반려받은 분이 보강해서 다시 요청해 오면
--   (구글폼·카톡 등 앱 밖에서 온다 — 앱 안 신청서는 닫혀 있다) 운영진이 이 함수로 심사 대기에 올린다.
--
-- 【구분】 새 칸을 만들지 않는다. **심사 대기(pending)인데 반려 사유(reject_reason)가 남아 있으면 「재심사」** 다.
--   관리자 화면은 그런 줄을 빨간 「재심사」 배지와 옅은 빨간 배경으로 보이고, 이전 반려 사유를 맨 위에 보인다.
--   다시 승인하면 사유는 지워지고(decide_kkut_application), 다시 반려하면 새 사유로 바뀐다.
--
-- 【하는 일】 반려된 신청만 올린다. 상태를 pending 으로, 결정한 시각·사람만 비운다. 반려 사유와 신청 내용은 그대로 둔다.
--   권한(can_lead)은 반려할 때 이미 꺼져 있고, 승인하기 전에는 그대로다.
--
-- ⚠️ 103·47 뒤에 돌린다. 여러 번 돌려도 된다.

CREATE OR REPLACE FUNCTION admin_requeue_kkut(p_user uuid) RETURNS void AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  UPDATE kkut_applications
     SET status = 'pending', decided_at = NULL, decided_by = NULL
   WHERE user_id = p_user AND status = 'rejected';
  IF NOT FOUND THEN RAISE EXCEPTION '반려된 신청만 재심사로 올릴 수 있어요'; END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_requeue_kkut(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_requeue_kkut(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 아무도 옮기지 않는다. 기대: 함수 1
SELECT count(*) AS 함수_1이어야 FROM pg_proc WHERE proname = 'admin_requeue_kkut';
