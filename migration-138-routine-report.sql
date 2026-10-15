-- 한끗독서 마이그레이션 138
-- 루틴별 결과 리포트 — 후원 기업·외부에 공유하는 한 장짜리 (2026-10-15 사용자)
--
-- 【하는 일】 admin_routine_report(루틴, 완주 기준 %) — 루틴 하나의 성과를 한 번에 모아 돌려준다. 관리자 통계의 루틴별 표에서 쓴다.
--   · 루틴 개요: 이름, 기간, 맡은 끗짱(닉네임), 함께한 책방, 후원 기업(있으면)
--   · 참여 청소년 수, 완주 인원(기간의 70% 이상 인증), 전체 인증 수, 인증한 날 합계, 한 사람 평균 인증일
--   · 날짜별 인증한 청소년 수 (기간 안의 매일)
--   · 아이들이 읽은 책과 읽은 사람 수, 공유회 참석(공유회가 걸린 루틴만), 서로 남긴 댓글·좋아요 수
--   · 공개로 켠 문장·후기 (관리자가 화면에서 2개씩 고른다)
--
-- 【세는 사람】 승인되어 참여한 **청소년만**. 끗짱과 탈퇴한 회원은 뺀다 (통계와 같다).
-- 【담지 않는 것】 청소년 이름·사진·지역, 책값·정산 금액, 읽은 쪽수 (쪽수 집계 시작일이 정해지면 그때 넣는다).
--
-- ⚠️ 58·105·136 뒤에 돌린다. 여러 번 돌려도 된다. 아무것도 바꾸지 않는다 (읽기만 한다).

CREATE OR REPLACE FUNCTION admin_routine_report(p_routine bigint, p_pct int DEFAULT 70) RETURNS jsonb AS $$
DECLARE
  r routines%ROWTYPE;
  v_pct   int  := LEAST(GREATEST(COALESCE(p_pct, 70), 1), 100);
  v_today date := (now() AT TIME ZONE 'Asia/Seoul')::date;
  v_days  int; v_end date; v_out jsonb;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;
  SELECT * INTO r FROM routines WHERE id = p_routine;
  IF NOT FOUND THEN RAISE EXCEPTION '그런 루틴이 없어요'; END IF;
  v_days := GREATEST((r.end_date - r.start_date) + 1, 1);
  v_end  := LEAST(r.end_date, v_today);

  WITH ps AS (
    SELECT rp.user_id, rp.met_at
      FROM routine_participants rp JOIN profiles p ON p.id = rp.user_id
     WHERE rp.routine_id = p_routine AND rp.status = 'approved'
       AND NOT COALESCE(p.can_lead, false) AND p.withdrawn_at IS NULL
  ),
  cd AS (
    SELECT c.id, c.user_id, c.cert_date FROM certifications c
     WHERE c.routine_id = p_routine AND c.user_id IN (SELECT user_id FROM ps)
  ),
  per AS (
    SELECT user_id, count(DISTINCT cert_date) AS n FROM cd GROUP BY user_id
  )
  SELECT jsonb_build_object(
    'routine', jsonb_build_object(
        'id', r.id, 'title', r.title, 'emoji', r.emoji, 'start', r.start_date, 'end', r.end_date,
        'days', v_days, 'status', r.status, 'canceled', r.canceled, 'kind', COALESCE(r.kind, 'book'),
        'sponsor', NULLIF(btrim(COALESCE(r.sponsor_name, '')), ''),
        'store', (SELECT name FROM bookstores WHERE id = r.bookstore_id),
        'lead', (SELECT NULLIF(btrim(COALESCE(nick, '')), '') FROM profiles WHERE id = r.led_by),
        'meetup_required', COALESCE(r.meetup_required, false)),
    'pct', v_pct,
    'people', (SELECT count(*) FROM ps),
    'done', (SELECT count(*) FROM ps LEFT JOIN per ON per.user_id = ps.user_id
              WHERE COALESCE(per.n, 0) >= CEIL(v_days * v_pct / 100.0)),
    'certs', (SELECT count(*) FROM cd),
    'cert_days', (SELECT COALESCE(sum(n), 0) FROM per),
    'avg_days', (SELECT COALESCE(round(avg(COALESCE(per.n, 0))::numeric, 1), 0)
                   FROM ps LEFT JOIN per ON per.user_id = ps.user_id),
    'daily', COALESCE((SELECT jsonb_agg(jsonb_build_object('d', g.d, 'n',
                         (SELECT count(DISTINCT cd.user_id) FROM cd WHERE cd.cert_date = g.d)) ORDER BY g.d)
                         FROM (SELECT x::date AS d FROM generate_series(r.start_date::timestamp, v_end::timestamp, interval '1 day') x) g),
                       '[]'::jsonb),
    'books', COALESCE((SELECT jsonb_agg(jsonb_build_object('title', t, 'readers', n) ORDER BY n DESC, t)
                         FROM (SELECT btrim(b.title) AS t, count(DISTINCT b.user_id) AS n
                                 FROM routine_books b
                                WHERE b.routine_id = p_routine AND b.user_id IN (SELECT user_id FROM ps)
                                GROUP BY 1) x), '[]'::jsonb),
    'meetup', CASE WHEN COALESCE(r.meetup_required, false)
                   THEN jsonb_build_object('attended', (SELECT count(*) FROM ps WHERE met_at IS NOT NULL),
                                           'people', (SELECT count(*) FROM ps))
                   ELSE NULL END,
    'comments', (SELECT count(*) FROM cert_comments m
                  WHERE m.cert_id IN (SELECT id FROM certifications WHERE routine_id = p_routine)),
    'likes', (SELECT count(*) FROM cert_likes l
               WHERE l.cert_id IN (SELECT id FROM certifications WHERE routine_id = p_routine)),
    'quotes', COALESCE((SELECT jsonb_agg(jsonb_build_object('quote', quote, 'book_title', book_title) ORDER BY created_at DESC)
                          FROM (SELECT quote, book_title, created_at FROM certifications
                                 WHERE routine_id = p_routine AND quote_public AND COALESCE(btrim(quote), '') <> ''
                                 ORDER BY created_at DESC LIMIT 30) q), '[]'::jsonb),
    'reviews', COALESCE((SELECT jsonb_agg(jsonb_build_object('content', content, 'kind', kind, 'book_title', book_title) ORDER BY created_at DESC)
                          FROM (SELECT content, kind, book_title, created_at FROM reviews
                                 WHERE routine_id = p_routine AND is_public
                                 ORDER BY created_at DESC LIMIT 30) v), '[]'::jsonb)
  ) INTO v_out;
  RETURN v_out;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE SET search_path = public;
REVOKE EXECUTE ON FUNCTION admin_routine_report(bigint, int) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION admin_routine_report(bigint, int) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 가장 최근에 시작한 루틴 하나로 읽어 본다. 기대: 함수 1 / 아래 숫자가 관리자 통계의 그 루틴 숫자와 맞는다
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'admin_routine_report') AS 함수_1이어야,
       r.id AS 루틴, r.title AS 이름,
       admin_routine_report(r.id) -> 'people'    AS 참여_청소년,
       admin_routine_report(r.id) -> 'done'      AS 완주,
       admin_routine_report(r.id) -> 'certs'     AS 전체_인증,
       admin_routine_report(r.id) -> 'avg_days'  AS 평균_인증일
  FROM routines r WHERE r.status IN ('active', 'done') AND NOT r.canceled ORDER BY r.start_date DESC, r.id DESC LIMIT 3;
