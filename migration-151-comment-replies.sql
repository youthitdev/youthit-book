-- 한끗독서 마이그레이션 151
-- 댓글에 답글(대댓글) — 한 단계만 (2026-10-27 사용자)
--
-- 【정해진 것】
--   · 답글은 댓글 밑에 한 단계만 단다. 답글에 또 답글은 못 단다.
--   · **답글에는 나다움이 없다.** 댓글 1N(하루 5개까지)은 그대로, 답글은 세지 않는다.
--   · 내 댓글에 답글이 달리면 댓글 쓴 사람에게 알림이 간다(「~님이 내 댓글에 답글을 남겼어요」).
--     인증 주인·끗짱이 그 사람이기도 하면 알림은 한 번만 간다.
--   · 댓글을 지우면 그 밑 답글도 같이 지워진다.
--
-- 【무엇을】
--   1. cert_comments.parent_id 칸 (비어 있으면 그냥 댓글, 값이 있으면 그 댓글에 단 답글)
--   2. 같은 인증의 맨 위 댓글에만 답글을 달 수 있게 검사 (check_comment_parent)
--   3. 나다움 계산(dokseo_points): 답글은 뺀다 — 76번의 식에 한 줄만 더했다
--   4. 알림(on_comment_to_lead): 116번의 식에 답글 몫만 더했다
--
-- ⚠️ 76(dokseo_points) · 116(on_comment_to_lead) 뒤에 돌린다. 여러 번 돌려도 된다.

ALTER TABLE cert_comments ADD COLUMN IF NOT EXISTS parent_id bigint REFERENCES cert_comments(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS cert_comments_parent_idx ON cert_comments (parent_id);

-- ── 2. 답글 검사 ───────────────────────────────────────
CREATE OR REPLACE FUNCTION check_comment_parent() RETURNS trigger AS $$
DECLARE p record;
BEGIN
  IF NEW.parent_id IS NULL THEN RETURN NEW; END IF;
  SELECT cert_id, parent_id INTO p FROM cert_comments WHERE id = NEW.parent_id;
  IF NOT FOUND OR p.cert_id <> NEW.cert_id THEN
    RAISE EXCEPTION '답글을 달 댓글을 찾지 못했어요';
  END IF;
  IF p.parent_id IS NOT NULL THEN
    RAISE EXCEPTION '답글에는 답글을 달 수 없어요';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

DROP TRIGGER IF EXISTS comments_parent_ok ON cert_comments;
CREATE TRIGGER comments_parent_ok BEFORE INSERT ON cert_comments
  FOR EACH ROW EXECUTE FUNCTION check_comment_parent();

-- ── 3. 나다움: 답글은 세지 않는다 ───────────────────────
CREATE OR REPLACE FUNCTION dokseo_points(p_user uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  v_u uuid := COALESCE(p_user, auth.uid());
  v_n int; v_cert int; v_cmt int; v_bonus int; v_next int; v_rev int; v_meet int;
  v_lost int;
  v_per int; v_ppc int; v_cap int; v_pm int; v_ms int[]; v_pr int; v_pb int; v_pmt int;
  v_points int; v_used int; v_earned int;
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요합니다'; END IF;
  IF v_u <> auth.uid() AND NOT is_admin() THEN RAISE EXCEPTION '권한이 없습니다'; END IF;

  SELECT points_per_voucher, points_per_comment, comment_daily_cap,
         points_per_milestone, bonus_milestones,
         points_per_review, points_per_bookreview, points_per_meetup
    INTO v_per, v_ppc, v_cap, v_pm, v_ms, v_pr, v_pb, v_pmt
    FROM dokseo_settings WHERE id = 1;
  v_per := GREATEST(COALESCE(v_per, 250), 1);
  v_ppc := COALESCE(v_ppc, 1);
  v_cap := GREATEST(COALESCE(v_cap, 5), 0);
  v_pm  := COALESCE(v_pm, 10);
  v_ms  := COALESCE(v_ms, '{10,30,66,100,200}');
  v_pr  := COALESCE(v_pr, 30);
  v_pb  := COALESCE(v_pb, 30);
  v_pmt := COALESCE(v_pmt, 50);

  -- 하루에 한 번이다. 같은 날 세 권을 읽어도 그날치 한 번.
  -- 공유회를 지나쳐 버린 루틴은 여기서 빠진다
  SELECT COALESCE(sum(ppc), 0) INTO v_cert FROM (
    SELECT max(r.points_per_cert) AS ppc
      FROM certifications c JOIN routines r ON r.id = c.routine_id
     WHERE c.user_id = v_u
       AND NOT meetup_missed(r.id, v_u)
     GROUP BY c.routine_id, c.cert_date) t;

  -- 못 간 루틴에서 날아간 몫. 화면에 「얼마가 묶였는지」를 말해 주려는 것이다
  SELECT COALESCE(sum(ppc), 0) INTO v_lost FROM (
    SELECT max(r.points_per_cert) AS ppc
      FROM certifications c JOIN routines r ON r.id = c.routine_id
     WHERE c.user_id = v_u
       AND meetup_missed(r.id, v_u)
     GROUP BY c.routine_id, c.cert_date) t;

  -- 읽은 날은 읽은 날이다. 이정표는 그대로 센다
  SELECT count(DISTINCT cert_date) INTO v_n FROM certifications WHERE user_id = v_u;

  SELECT COALESCE(sum(LEAST(n, v_cap)), 0) * v_ppc INTO v_cmt
    FROM (
      SELECT count(*) AS n
        FROM cert_comments m JOIN certifications c ON c.id = m.cert_id
       WHERE m.user_id = v_u AND c.user_id <> v_u
         AND m.parent_id IS NULL      -- 답글에는 나다움이 없다 (2026-10-27)
       GROUP BY (m.created_at AT TIME ZONE 'Asia/Seoul')::date
    ) t;

  SELECT COALESCE(count(*), 0) * v_pm INTO v_bonus FROM unnest(v_ms) m WHERE m <= v_n;
  SELECT min(m) INTO v_next FROM unnest(v_ms) m WHERE m > v_n;

  SELECT COALESCE(count(*) FILTER (WHERE kind = 'routine'), 0) * v_pr
       + COALESCE(count(*) FILTER (WHERE kind = 'book'),    0) * v_pb
    INTO v_rev FROM reviews WHERE user_id = v_u;

  SELECT COALESCE(count(*), 0) * v_pmt INTO v_meet
    FROM routine_participants rp
    JOIN routines ro ON ro.id = rp.routine_id
   WHERE rp.user_id = v_u AND rp.met_at IS NOT NULL AND ro.meetup_required;

  v_points := v_cert + v_cmt + v_bonus + v_rev + v_meet;

  SELECT count(*) INTO v_used FROM book_purchases
   WHERE user_id = v_u AND status IN ('pending', 'settled');

  v_earned := v_points / v_per;

  RETURN jsonb_build_object(
    'points',       v_points,
    'cert_count',   v_n,
    'from_cert',    v_cert,
    'from_comment', v_cmt,
    'from_bonus',   v_bonus,
    'from_review',  v_rev,
    'from_meetup',  v_meet,
    'lost_meetup',  v_lost,
    'next_milestone', v_next,
    'per_voucher',  v_per,
    'earned',       v_earned,
    'used',         v_used,
    'left',         GREATEST(0, v_earned - v_used),
    'to_next',      v_per - (v_points % v_per)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION dokseo_points(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION dokseo_points(uuid) TO authenticated;

-- ── 4. 알림: 내 댓글에 답글이 달리면 ────────────────────
CREATE OR REPLACE FUNCTION on_comment_to_lead() RETURNS trigger AS $$
DECLARE v_rid bigint; v_author uuid; v_title text; v_lead uuid; v_who text; v_text text; v_body text; v_pa uuid; v_link text;
BEGIN
  SELECT c.routine_id, c.user_id INTO v_rid, v_author FROM certifications c WHERE c.id = NEW.cert_id;
  IF v_rid IS NULL THEN RETURN NEW; END IF;
  SELECT r.title, r.led_by INTO v_title, v_lead FROM routines r WHERE r.id = v_rid;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  v_text := btrim(regexp_replace(COALESCE(NEW.content, ''), '\s+', ' ', 'g'));
  IF char_length(v_text) > 30 THEN v_text := left(v_text, 30) || '…'; END IF;
  -- 누가 했는지는 제목에, 댓글 내용은 내용에. 루틴 이름은 넣지 않는다
  v_body := COALESCE(NULLIF(v_text, ''), '');

  v_link := '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id;

  -- 답글이면 원래 댓글을 쓴 사람에게 알린다 (자기 댓글에 자기가 단 답글은 제외).
  -- 이 사람이 인증 주인이나 끗짱이기도 하면 아래 몫은 건너뛴다 — 알림이 둘 가지 않게
  IF NEW.parent_id IS NOT NULL THEN
    SELECT m.user_id INTO v_pa FROM cert_comments m WHERE m.id = NEW.parent_id;
    IF v_pa IS NOT NULL AND v_pa <> NEW.user_id THEN
      PERFORM notify_push(v_pa, COALESCE(v_who, '친구') || '님이 내 댓글에 답글을 남겼어요 💬', v_body, v_link, 'friends');
    END IF;
  END IF;

  -- 내 인증에 달린 댓글 (끗짱이 쓴 인증이면 아래 끗짱 몫으로 한 번만 간다)
  IF v_author IS NOT NULL AND v_author <> NEW.user_id AND v_author IS DISTINCT FROM v_lead
     AND v_author IS DISTINCT FROM v_pa THEN
    PERFORM notify_push(v_author, COALESCE(v_who, '친구') || '님이 내 인증에 댓글을 남겼어요 💬', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id, 'friends');
  END IF;
  -- 끗짱 몫. 끗짱이 직접 단 댓글은 알리지 않는다
  IF v_lead IS NOT NULL AND v_lead <> NEW.user_id AND v_lead IS DISTINCT FROM v_pa THEN
    PERFORM notify_push(v_lead, COALESCE(v_who, '친구') || '님이 댓글을 남겼어요 💬', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id, 'friends');
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
SELECT (SELECT count(*) FROM information_schema.columns WHERE table_name = 'cert_comments' AND column_name = 'parent_id') AS 칸_1이어야,
       (SELECT count(*) FROM pg_trigger WHERE tgname = 'comments_parent_ok')                                         AS 검사_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'dokseo_points'      AND prosrc LIKE '%parent_id IS NULL%')     AS 나다움_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'on_comment_to_lead' AND prosrc LIKE '%님이 내 댓글에 답글을%')  AS 알림_1이어야;
