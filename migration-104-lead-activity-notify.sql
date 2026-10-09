-- 한끗독서 마이그레이션 104
-- 내 루틴의 아이가 인증을 올리거나 댓글을 달면 끗짱에게 알린다
--
-- 【왜】 끗짱에게 가는 알림은 「새 친구가 들어왔어요」뿐이었다. 아이가 인증을 올려도,
--   댓글을 남겨도 끗짱은 앱을 열어 봐야만 알았다. 끗짱이 아이에게 반응해 주는 것이 이
--   서비스의 핵심인데 그 신호가 없었다 (2026-10-09 사용자).
--
-- 【많이 울리지 않나】 모든 루틴이 아니라 **내가 맡은 루틴**의 아이들만이다. 한 루틴은 여덟 명
--   안팎이라 하루 여덟 번 안쪽이다. 사용자가 이 정도는 괜찮다고 정했다.
--
-- 【누구에게】 그 루틴의 끗짱(led_by) 한 명. 끗짱이 없는 루틴(운영진이 보는 루틴)은 보내지 않는다 —
--   운영진 전원에게 보내면 너무 많다.
--
-- 【자기 자신에게는 안 보낸다】 끗짱이 제 인증을 올리거나 제 댓글을 달 때.
--
-- 【고칠 때는 안 보낸다】 인증 수정은 UPDATE 로 들어간다. INSERT 에만 건다 (59 와 같은 이유).
--
-- 【알림이 터져도 저장은 된다】 EXCEPTION 으로 막아 둔다. 인증과 댓글이 알림 때문에 안 올라가면 안 된다.
--
-- ⚠️ 39(notify_push) 뒤에 돌린다.

-- ── 1. 인증이 올라오면 ─────────────────────────────────
CREATE OR REPLACE FUNCTION on_cert_to_lead() RETURNS trigger AS $$
DECLARE v_title text; v_lead uuid; v_who text;
BEGIN
  SELECT r.title, r.led_by INTO v_title, v_lead FROM routines r WHERE r.id = NEW.routine_id;
  IF v_lead IS NULL OR v_lead = NEW.user_id THEN RETURN NEW; END IF;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;

  PERFORM notify_push(v_lead, '인증이 올라왔어요 📖',
    COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '친구')
      || COALESCE(' · ' || NULLIF(btrim(NEW.book_title), ''), ''),
    '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS certs_lead_notify ON certifications;
CREATE TRIGGER certs_lead_notify AFTER INSERT ON certifications
  FOR EACH ROW EXECUTE FUNCTION on_cert_to_lead();

-- ── 2. 댓글이 달리면 ───────────────────────────────────
-- 댓글은 인증 한 장에 달린다. 그 인증이 속한 루틴의 끗짱에게 간다.
-- 내용은 앞 30자만 보인다 — 알림 화면에서 읽히는 만큼이면 충분하다
CREATE OR REPLACE FUNCTION on_comment_to_lead() RETURNS trigger AS $$
DECLARE v_rid bigint; v_title text; v_lead uuid; v_who text; v_text text;
BEGIN
  SELECT c.routine_id INTO v_rid FROM certifications c WHERE c.id = NEW.cert_id;
  IF v_rid IS NULL THEN RETURN NEW; END IF;
  SELECT r.title, r.led_by INTO v_title, v_lead FROM routines r WHERE r.id = v_rid;
  IF v_lead IS NULL OR v_lead = NEW.user_id THEN RETURN NEW; END IF;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  v_text := btrim(regexp_replace(COALESCE(NEW.content, ''), '\s+', ' ', 'g'));
  IF char_length(v_text) > 30 THEN v_text := left(v_text, 30) || '…'; END IF;

  PERFORM notify_push(v_lead, '댓글이 달렸어요 💬',
    COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '친구')
      || COALESCE(': ' || NULLIF(v_text, ''), ''),
    '/youthit-book/app.html?tab=cert&routine=' || v_rid);
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
