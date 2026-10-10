-- 한끗독서 마이그레이션 107
-- 인증 신고하기
--
-- 【왜】 청소년끼리 인증 사진을 서로 본다. 부적절한 사진·개인정보가 올라왔을 때 운영진이 알 길이
--   없었다 (프로필 사진 내리기만 있었다). 신고 → 운영진 알림 → 내리기/문제없음 순서로 만든다.
--
-- 【누가 신고하나】 같은 루틴 사람(볼 수 있는 인증만, can_see_cert). 내 인증은 신고할 수 없다.
--   한 사람이 같은 인증을 두 번 신고할 수는 없다.
--
-- 【신고한 사람은 숨긴다】 인증을 올린 사람은 누가 신고했는지 모른다. 표를 읽는 길이 없다
--   (본인 것과 운영진만 읽힌다). 내려갈 때 알림에도 신고자를 적지 않는다.
--
-- 【내리기 = 사진·글을 비운다】 인증 기록(날짜·책·포인트)은 남긴다. 사진과 소감·문장만 지운다.
--   인증을 통째로 지우면 아이가 쌓은 포인트까지 사라진다 — 문제는 내용이지 읽었다는 사실이 아니다.
--   (사진 파일은 관리자 화면이 따로 지운다)
--
-- ⚠️ 21~23(can_see_cert) · 39(notify_push) · 78(admin_user_ids) 뒤에 돌린다.

CREATE TABLE IF NOT EXISTS cert_reports (
  id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  cert_id     bigint NOT NULL REFERENCES certifications(id) ON DELETE CASCADE,
  reporter_id uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  reason      text   NOT NULL CHECK (reason IN ('photo', 'privacy', 'rude', 'other')),
  note        text,
  status      text   NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'removed', 'dismissed')),
  created_at  timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  UNIQUE (cert_id, reporter_id)
);
CREATE INDEX IF NOT EXISTS cert_reports_open_idx ON cert_reports(status, created_at DESC);

ALTER TABLE cert_reports ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS reports_read ON cert_reports;
-- 본인이 한 신고와 운영진만. 쓰기는 함수로만 한다
CREATE POLICY reports_read ON cert_reports FOR SELECT TO authenticated
  USING (reporter_id = auth.uid() OR is_admin());

-- ── 신고하기 ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION report_cert(p_cert bigint, p_reason text, p_note text DEFAULT NULL)
RETURNS void AS $$
DECLARE v_author uuid; v_rid bigint; v_title text; v_who text; v_first boolean; a uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  IF p_reason NOT IN ('photo', 'privacy', 'rude', 'other') THEN RAISE EXCEPTION '이유를 골라 주세요'; END IF;
  IF NOT can_see_cert(p_cert) THEN RAISE EXCEPTION '볼 수 없는 인증이에요'; END IF;

  SELECT c.user_id, c.routine_id INTO v_author, v_rid FROM certifications c WHERE c.id = p_cert;
  IF v_author IS NULL THEN RAISE EXCEPTION '없는 인증이에요'; END IF;
  IF v_author = auth.uid() THEN RAISE EXCEPTION '내 인증은 신고할 수 없어요'; END IF;

  -- 아직 처리 전인 신고가 이미 있는 인증이면 운영진에게 다시 알리지 않는다 (같은 인증에 알림이 쌓이지 않게)
  v_first := NOT EXISTS (SELECT 1 FROM cert_reports WHERE cert_id = p_cert AND status = 'open');

  BEGIN
    INSERT INTO cert_reports(cert_id, reporter_id, reason, note)
    VALUES (p_cert, auth.uid(), p_reason, NULLIF(btrim(COALESCE(p_note, '')), ''));
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION '이미 신고했어요';
  END;

  IF v_first THEN
    SELECT r.title INTO v_title FROM routines r WHERE r.id = v_rid;
    SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '회원')
      INTO v_who FROM profiles p WHERE p.id = v_author;
    FOR a IN SELECT * FROM admin_user_ids() LOOP
      PERFORM notify_push(a, '인증 신고가 들어왔어요 🚩',
        COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '회원'),
        '/youthit-book/admin.html#reports');
    END LOOP;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION report_cert(bigint, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION report_cert(bigint, text, text) TO authenticated;

-- ── 운영진이 처리한다 ──────────────────────────────────
-- p_action: 'removed' = 사진·글을 내린다 / 'dismissed' = 문제없음
-- 같은 인증에 쌓인 처리 전 신고를 한꺼번에 닫는다
CREATE OR REPLACE FUNCTION admin_resolve_report(p_cert bigint, p_action text)
RETURNS void AS $$
DECLARE v_author uuid;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION '운영진만 처리할 수 있어요'; END IF;
  IF p_action NOT IN ('removed', 'dismissed') THEN RAISE EXCEPTION '처리 방법이 맞지 않아요'; END IF;

  IF p_action = 'removed' THEN
    UPDATE certifications SET photo_urls = '{}', content = NULL, quote = NULL
     WHERE id = p_cert RETURNING user_id INTO v_author;
    IF v_author IS NOT NULL THEN
      PERFORM notify_push(v_author, '인증 사진이 내려갔어요',
        '운영 기준에 맞지 않아 내렸어요. 궁금한 점은 문의해 주세요. 오늘 인증은 그대로 인정돼요.',
        '/youthit-book/app.html?tab=cert');
    END IF;
  END IF;

  UPDATE cert_reports SET status = p_action, resolved_at = now()
   WHERE cert_id = p_cert AND status = 'open';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION admin_resolve_report(bigint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_resolve_report(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 알림을 보내지 않는다. 기대: 표 1, 정책 1, 함수 둘 다 1, 칸 둘 다 1
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_name = 'cert_reports')       AS 표_1이어야,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'cert_reports')                      AS 정책_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'report_cert')                             AS 신고함수_1,
       (SELECT count(*) FROM pg_proc WHERE proname = 'admin_resolve_report')                    AS 처리함수_1,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'certifications' AND column_name IN ('content', 'quote', 'photo_urls')) AS 인증칸_3이어야;
