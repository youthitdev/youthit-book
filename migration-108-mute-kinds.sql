-- 한끗독서 마이그레이션 108
-- 알림 종류별 끄기 (친구들 소식 · 콕)
--
-- 【왜】 인증·댓글·좋아요 알림을 늘렸다. 한 루틴 여덟 명이면 하루 여러 번 울린다. 많아서 알림을 통째로
--   꺼 버리면 정작 중요한 알림(승인·교환)까지 놓친다. 이 둘만 따로 끌 수 있게 한다.
--
-- 【꺼진 종류는 아예 만들지 않는다】 푸시만 막고 알림함에 쌓이면 안 읽은 숫자(홈 화면 아이콘)가 계속 오른다.
--   그래서 꺼 둔 종류는 알림함에도 남기지 않는다. 다시 켜면 그때부터 온다.
--
-- 【종류】 'friends' = 친구들 소식(인증이 올라옴 · 댓글 · 좋아요), 'poke' = 콕.
--   승인·교환·공지·리마인더는 끌 수 없다 (리마인더는 따로 스위치가 있다).
--
-- 【notify_push 가 바뀐다】 다섯째 인자 p_kind 가 붙는다. 같은 이름으로 인자만 다른 함수를 두면
--   네 개로 부를 때 「어느 함수인지 모호하다」는 오류가 난다. 그래서 옛 함수는 지우고 새로 만든다.
--   부르는 쪽은 그대로 네 개를 넘겨도 된다 (다섯째는 비워 두면 끌 수 없는 알림이다).
--
-- ⚠️ 39(notify_push) · 50(콕) · 104(인증·댓글) · 106(좋아요) 뒤에 돌린다 —
--   아래에서 그 함수들을 종류가 붙은 판으로 다시 만든다. 이 파일을 돌린 뒤에는 104·106 을 다시 돌리지 않는다
--   (돌리면 종류 없는 옛 판으로 돌아간다).

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS mute_kinds text[] NOT NULL DEFAULT '{}';
COMMENT ON COLUMN profiles.mute_kinds IS '꺼 둔 알림 종류. friends(친구들 소식) · poke(콕)';

-- ── notify_push: 꺼 둔 종류면 만들지 않는다 ────────────
DROP FUNCTION IF EXISTS notify_push(uuid, text, text, text);
CREATE OR REPLACE FUNCTION notify_push(
  p_user uuid, p_title text, p_body text DEFAULT '', p_url text DEFAULT NULL, p_kind text DEFAULT NULL
) RETURNS void AS $$
DECLARE
  sr_key text;
  v_url  text := COALESCE(p_url, '/youthit-book/app.html');
BEGIN
  IF p_user IS NULL THEN RETURN; END IF;

  -- 끌 수 있는 종류인데 이 사람이 꺼 뒀으면 알림함에도 남기지 않는다
  IF p_kind IS NOT NULL AND EXISTS (SELECT 1 FROM profiles WHERE id = p_user AND p_kind = ANY(mute_kinds)) THEN
    RETURN;
  END IF;

  INSERT INTO notifications(user_id, title, body, link) VALUES (p_user, p_title, p_body, v_url);

  SELECT decrypted_secret INTO sr_key FROM vault.decrypted_secrets WHERE name = 'sr_key_for_push';
  IF sr_key IS NULL THEN RETURN; END IF;   -- 키가 없으면 알림함만. 조용히 넘어간다

  PERFORM net.http_post(
    url     := 'https://qvpahwvihvkasrznboaa.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'Authorization', 'Bearer ' || sr_key),
    body    := jsonb_build_object('user_id', p_user, 'title', p_title,
                                  'body', p_body, 'url', v_url, 'from_db', true)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION notify_push(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated;

-- ── 종류가 붙은 판으로 다시 만든다 ─────────────────────
-- 콕 (50)
CREATE OR REPLACE FUNCTION on_nudge() RETURNS trigger AS $$
DECLARE v_title text; v_me text;
BEGIN
  SELECT title INTO v_title FROM routines WHERE id = NEW.routine_id;
  SELECT COALESCE(nick, name) INTO v_me FROM profiles WHERE id = NEW.from_id;
  -- 숫자도 「며칠째」도 넣지 않는다. 찌르기지 추궁이 아니다
  PERFORM notify_push(NEW.to_id,
    COALESCE(v_me, '끗짱') || ' 끗짱이 콕 찔렀어요 👉',
    COALESCE(v_title, '루틴') || ' · 오늘 한 장 어때요?',
    '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id, 'poke');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 인증이 올라오면 (104)
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
      '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id || '&cert=' || NEW.id, 'friends');
  END LOOP;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 댓글이 달리면 (104)
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
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id, 'friends');
  END IF;
  -- 끗짱 몫. 끗짱이 직접 단 댓글은 알리지 않는다
  IF v_lead IS NOT NULL AND v_lead <> NEW.user_id THEN
    PERFORM notify_push(v_lead, '댓글이 달렸어요 💬', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id, 'friends');
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 좋아요 (106)
CREATE OR REPLACE FUNCTION on_like_notify() RETURNS trigger AS $$
DECLARE v_author uuid; v_rid bigint; v_title text; v_who text; v_body text; v_link text;
BEGIN
  SELECT c.user_id, c.routine_id INTO v_author, v_rid FROM certifications c WHERE c.id = NEW.cert_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;

  SELECT r.title INTO v_title FROM routines r WHERE r.id = v_rid;
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  v_body := COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '친구') || '님이 좋아해요';
  v_link := '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id;   -- 누르면 그 인증으로

  -- 하루 안에 같은 알림이 이미 갔으면 다시 보내지 않는다 (눌렀다 뗐다 대비)
  IF EXISTS (SELECT 1 FROM notifications n
              WHERE n.user_id = v_author AND n.title = '인증에 ❤️가 달렸어요'
                AND n.body = v_body
                AND n.link = v_link
                AND n.created_at > now() - interval '1 day') THEN
    RETURN NEW;
  END IF;

  PERFORM notify_push(v_author, '인증에 ❤️가 달렸어요', v_body, v_link, 'friends');
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 알림을 보내지 않는다. 기대: 알림함수 1, 칸 1, 종류 붙은 본문 4
SELECT (SELECT count(*) FROM pg_proc WHERE proname = 'notify_push')                             AS 알림함수_1이어야,
       (SELECT count(*) FROM information_schema.columns
         WHERE table_name = 'profiles' AND column_name = 'mute_kinds')                          AS 칸_1이어야,
       (SELECT count(*) FROM pg_proc
         WHERE proname IN ('on_nudge', 'on_cert_to_lead', 'on_comment_to_lead', 'on_like_notify')
           AND (prosrc LIKE '%''friends'')%' OR prosrc LIKE '%''poke'')%'))                     AS 종류붙은_본문_4여야;
