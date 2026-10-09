-- 한끗독서 마이그레이션 104
-- 같은 루틴 사람이 인증을 올리거나 댓글을 달면 알린다 (끗짱과 아이 모두)
--
-- 【왜】 끗짱에게 가는 알림은 「새 친구가 들어왔어요」뿐이었다. 아이에게는 댓글 알림이 아예 없었다.
--   인증을 올려도, 댓글을 남겨도 상대는 앱을 열어 봐야만 알았다. 서로 반응해 주는 것이 이 서비스의
--   핵심인데 그 신호가 없었다 (2026-10-09 사용자).
--
-- 【누구에게】
--   · 인증이 올라오면: 그 루틴의 **끗짱과 승인된 참여자 모두** (올린 사람만 빼고)
--   · 댓글이 달리면 : **그 인증을 올린 사람**과 **그 루틴의 끗짱** (댓글 단 사람만 빼고)
--   모든 루틴이 아니라 **내가 속한 루틴**의 사람들 일이다. 한 루틴은 여덟 명 안팎이다.
--
-- 【겹쳐 보내지 않는다】 끗짱이 참여자 표에도 있는 경우, 인증 알림은 한 번만 간다.
--   인증을 올린 사람이 끗짱이면 댓글 알림도 한 번만 간다 (끗짱 몫으로).
--
-- 【알림을 누르면 그 인증으로】 링크에 &cert=번호 를 붙인다. 앱이 그 인증 한 장을 바로 연다.
--   (전에는 루틴 소개 화면으로 가서 댓글이 안 보였다)
--
-- 【고칠 때는 안 보낸다】 인증 수정은 UPDATE 로 들어간다. INSERT 에만 건다 (59 와 같은 이유).
--
-- 【알림이 터져도 저장은 된다】 EXCEPTION 으로 막아 둔다. 인증과 댓글이 알림 때문에 안 올라가면 안 된다.
--
-- ⚠️ 39(notify_push) 뒤에 돌린다. 이미 한 번 돌렸어도 다시 돌려도 된다 (CREATE OR REPLACE).

-- ── 1. 인증이 올라오면 ─────────────────────────────────
CREATE OR REPLACE FUNCTION on_cert_to_lead() RETURNS trigger AS $$
DECLARE v_title text; v_lead uuid; v_who text; v_body text; u uuid;
BEGIN
  SELECT r.title, r.led_by INTO v_title, v_lead FROM routines r WHERE r.id = NEW.routine_id;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  v_body := COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '친구')
            || COALESCE(' · ' || NULLIF(btrim(NEW.book_title), ''), '');

  -- 끗짱 + 승인된 참여자. 올린 사람은 뺀다. UNION 이 겹침도 걷어 준다
  FOR u IN
    SELECT x FROM (
      SELECT v_lead AS x
      UNION
      SELECT rp.user_id FROM routine_participants rp
       WHERE rp.routine_id = NEW.routine_id AND rp.status = 'approved'
    ) t
    WHERE x IS NOT NULL AND x <> NEW.user_id
  LOOP
    PERFORM notify_push(u, '인증이 올라왔어요 📖', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id || '&cert=' || NEW.id);
  END LOOP;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS certs_lead_notify ON certifications;
CREATE TRIGGER certs_lead_notify AFTER INSERT ON certifications
  FOR EACH ROW EXECUTE FUNCTION on_cert_to_lead();

-- ── 2. 댓글이 달리면 ───────────────────────────────────
-- 댓글은 인증 한 장에 달린다. 인증을 올린 사람과 그 루틴의 끗짱에게 간다.
-- 내용은 앞 30자만 보인다 — 알림 화면에서 읽히는 만큼이면 충분하다
CREATE OR REPLACE FUNCTION on_comment_to_lead() RETURNS trigger AS $$
DECLARE v_rid bigint; v_author uuid; v_title text; v_lead uuid; v_who text; v_text text; v_body text;
BEGIN
  SELECT c.routine_id, c.user_id INTO v_rid, v_author FROM certifications c WHERE c.id = NEW.cert_id;
  IF v_rid IS NULL THEN RETURN NEW; END IF;
  SELECT r.title, r.led_by INTO v_title, v_lead FROM routines r WHERE r.id = v_rid;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  v_text := btrim(regexp_replace(COALESCE(NEW.content, ''), '\s+', ' ', 'g'));
  IF char_length(v_text) > 30 THEN v_text := left(v_text, 30) || '…'; END IF;
  v_body := COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '친구')
            || COALESCE(': ' || NULLIF(v_text, ''), '');

  -- 내 인증에 달린 댓글 (끗짱이 쓴 인증이면 아래 끗짱 몫으로 한 번만 간다)
  IF v_author IS NOT NULL AND v_author <> NEW.user_id AND v_author IS DISTINCT FROM v_lead THEN
    PERFORM notify_push(v_author, '내 인증에 댓글이 달렸어요 💬', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id);
  END IF;
  -- 끗짱 몫. 끗짱이 직접 단 댓글은 알리지 않는다
  IF v_lead IS NOT NULL AND v_lead <> NEW.user_id THEN
    PERFORM notify_push(v_lead, '댓글이 달렸어요 💬', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS comments_lead_notify ON cert_comments;
CREATE TRIGGER comments_lead_notify AFTER INSERT ON cert_comments
  FOR EACH ROW EXECUTE FUNCTION on_comment_to_lead();

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 방아쇠가 붙었는지만 본다. 알림을 실제로 보내지 않는다.
-- 기대: 방아쇠 둘 다 1, 함수 둘 다 1
SELECT (SELECT count(*) FROM pg_trigger WHERE tgname = 'certs_lead_notify'    AND NOT tgisinternal) AS 인증_방아쇠,
       (SELECT count(*) FROM pg_trigger WHERE tgname = 'comments_lead_notify' AND NOT tgisinternal) AS 댓글_방아쇠,
       (SELECT count(*) FROM pg_proc WHERE proname = 'on_cert_to_lead')    AS 인증_함수,
       (SELECT count(*) FROM pg_proc WHERE proname = 'on_comment_to_lead') AS 댓글_함수,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'certifications' AND column_name = 'book_title')  AS 책제목칸_1이어야,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'cert_comments' AND column_name IN ('cert_id','user_id','content')) AS 댓글칸_3이어야;
