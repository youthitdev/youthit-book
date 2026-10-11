-- 한끗독서 마이그레이션 116
-- 알림 문구 — 「누가 했는지」를 제목으로, 루틴 이름은 뺀다
--
-- 【왜】 지금은 제목에 「일」이 있고 누가 했는지는 아래 내용 줄에 있어서 잠금 화면에서 한눈에 안 읽힌다.
--   이름을 제목으로 올린다 (2026-10-11 사용자). 말투는 앱 전체와 같은 해요체다.
--   루틴 이름은 넣지 않는다 — 알림을 누르면 그 인증으로 열리고, 인증 목록에는 이미 루틴이 있다.
--
--   · 인증   : 「○○님이 인증했어요 📖」 / 「『책 제목』」
--   · 댓글   : 「○○님이 댓글을 남겼어요 💬」 (내 인증이면 「○○님이 내 인증에 댓글을 남겼어요 💬」) / 댓글 앞 30자
--   · 좋아요 : 「○○님이 내 인증을 좋아해요 ❤️」
--   · 완독   : 「○○님이 책을 완독했어요 🎉」 / 「『책 제목』」
--   · 콕·승인·정산 등 다른 알림은 그대로다.
--
-- 【이미 받은 알림은 그대로】 이 파일은 앞으로 오는 알림의 문구만 바꾼다. 알림함에 쌓인 옛 알림은 손대지 않는다.
--
-- 【종류(108)는 그대로】 친구들 소식(friends)으로 끌 수 있다. 아래 함수들은 108·109 의 함수를 문구만 바꿔 다시 만든 것이다 —
--   이 파일을 돌린 뒤에는 108·109 를 다시 돌리지 않는다 (돌리면 옛 문구로 돌아간다).
--
-- ⚠️ 108·109 뒤에 돌린다.

-- 인증이 올라오면
CREATE OR REPLACE FUNCTION on_cert_to_lead() RETURNS trigger AS $$
DECLARE v_title text; v_lead uuid; v_who text; v_body text; u uuid;
BEGIN
  SELECT r.title, r.led_by INTO v_title, v_lead FROM routines r WHERE r.id = NEW.routine_id;

  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  -- 누가 했는지는 제목에, 책은 내용에. 루틴 이름은 넣지 않는다 (알림을 누르면 그 인증이 열린다)
  v_body := COALESCE('『' || NULLIF(left(btrim(NEW.book_title), 40), '') || '』', '');

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
    PERFORM notify_push(u, COALESCE(v_who, '친구') || '님이 인증했어요 📖', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || NEW.routine_id || '&cert=' || NEW.id, 'friends');
  END LOOP;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 댓글이 달리면
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
  -- 누가 했는지는 제목에, 댓글 내용은 내용에. 루틴 이름은 넣지 않는다
  v_body := COALESCE(NULLIF(v_text, ''), '');

  -- 내 인증에 달린 댓글 (끗짱이 쓴 인증이면 아래 끗짱 몫으로 한 번만 간다)
  IF v_author IS NOT NULL AND v_author <> NEW.user_id AND v_author IS DISTINCT FROM v_lead THEN
    PERFORM notify_push(v_author, COALESCE(v_who, '친구') || '님이 내 인증에 댓글을 남겼어요 💬', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id, 'friends');
  END IF;
  -- 끗짱 몫. 끗짱이 직접 단 댓글은 알리지 않는다
  IF v_lead IS NOT NULL AND v_lead <> NEW.user_id THEN
    PERFORM notify_push(v_lead, COALESCE(v_who, '친구') || '님이 댓글을 남겼어요 💬', v_body,
      '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id, 'friends');
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 좋아요
CREATE OR REPLACE FUNCTION on_like_notify() RETURNS trigger AS $$
DECLARE v_author uuid; v_rid bigint; v_title text; v_who text; v_body text; v_link text; v_head text;
BEGIN
  SELECT c.user_id, c.routine_id INTO v_author, v_rid FROM certifications c WHERE c.id = NEW.cert_id;
  IF v_author IS NULL OR v_author = NEW.user_id THEN RETURN NEW; END IF;

  SELECT r.title INTO v_title FROM routines r WHERE r.id = v_rid;
  SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
    INTO v_who FROM profiles p WHERE p.id = NEW.user_id;
  -- 누가 했는지가 제목이다. 내용 줄은 비운다 (루틴 이름은 넣지 않는다)
  v_head := COALESCE(v_who, '친구') || '님이 내 인증을 좋아해요 ❤️';
  v_body := '';
  v_link := '/youthit-book/app.html?tab=cert&routine=' || v_rid || '&cert=' || NEW.cert_id;   -- 누르면 그 인증으로

  -- 하루 안에 같은 알림이 이미 갔으면 다시 보내지 않는다 (눌렀다 뗐다 대비)
  IF EXISTS (SELECT 1 FROM notifications n
              WHERE n.user_id = v_author AND n.title = v_head
                AND n.body = v_body
                AND n.link = v_link
                AND n.created_at > now() - interval '1 day') THEN
    RETURN NEW;
  END IF;

  PERFORM notify_push(v_author, v_head, v_body, v_link, 'friends');
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- 완독 도장 (109) — 도장 찍기 함수 전체를 문구만 바꿔 다시 만든다
CREATE OR REPLACE FUNCTION finish_book(p_routine bigint, p_title text, p_key text)
RETURNS void AS $$
DECLARE v_lead uuid; v_title text; v_who text; v_n int; u uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  IF btrim(COALESCE(p_title, '')) = '' OR btrim(COALESCE(p_key, '')) = '' THEN RAISE EXCEPTION '책 제목이 필요해요'; END IF;

  SELECT r.led_by, r.title INTO v_lead, v_title FROM routines r WHERE r.id = p_routine;
  IF NOT FOUND THEN RAISE EXCEPTION '없는 루틴이에요'; END IF;
  IF v_lead IS DISTINCT FROM auth.uid() AND NOT EXISTS (
       SELECT 1 FROM routine_participants rp
        WHERE rp.routine_id = p_routine AND rp.user_id = auth.uid() AND rp.status = 'approved') THEN
    RAISE EXCEPTION '이 루틴에 참여 중이 아니에요';
  END IF;

  INSERT INTO book_finishes(user_id, routine_id, book_key, book_title)
  VALUES (auth.uid(), p_routine, left(p_key, 120), left(btrim(p_title), 120))
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN RETURN; END IF;     -- 이미 찍혀 있다. 알림도 다시 보내지 않는다

  -- 알림은 안쪽 블록에 가둔다. 터져도 위에서 찍은 도장은 그대로 남는다
  BEGIN
    SELECT COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), ''), '친구')
      INTO v_who FROM profiles p WHERE p.id = auth.uid();

    FOR u IN
      SELECT x FROM (
        SELECT v_lead AS x
        UNION
        SELECT rp.user_id FROM routine_participants rp
         WHERE rp.routine_id = p_routine AND rp.status = 'approved'
      ) t
      WHERE x IS NOT NULL AND x <> auth.uid()
    LOOP
      PERFORM notify_push(u, COALESCE(v_who, '친구') || '님이 책을 완독했어요 🎉',
        '『' || left(btrim(p_title), 40) || '』',
        '/youthit-book/app.html?tab=cert&routine=' || p_routine, 'friends');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION finish_book(bigint, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION finish_book(bigint, text, text) TO authenticated;


NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 알림을 보내지 않는다. 기대: 새 문구가 들어간 본문 4
SELECT count(*) AS 새문구_본문_4여야
  FROM pg_proc
 WHERE (proname = 'on_cert_to_lead'    AND prosrc LIKE '%님이 인증했어요%')
    OR (proname = 'on_comment_to_lead' AND prosrc LIKE '%님이 댓글을 남겼어요%')
    OR (proname = 'on_like_notify'     AND prosrc LIKE '%님이 내 인증을 좋아해요%')
    OR (proname = 'finish_book'        AND prosrc LIKE '%님이 책을 완독했어요%');
