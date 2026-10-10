-- 한끗독서 마이그레이션 109
-- 완독 도장 — 책을 다 읽었다고 표시한다
--
-- 【왜】 쪽수는 쌓이는데 「끝냈다」는 순간이 없었다. 책 한 권을 끝낸 날은 아이에게 큰 날이다.
--   인증 화면에서 「이 책, 다 읽었어요」를 누르면 책 표지에 완독 도장이 찍히고, 같은 루틴 사람들에게
--   「○○가 책을 완독했어요 🎉」가 간다.
--
-- 【무엇을 저장하나】 (사람, 루틴, 책) 하나에 한 줄. 책은 제목에서 띄어쓰기·문장부호를 걷은 값(book_key)으로 구분한다
--   — 앱이 같은 책을 묶는 방식(loose)과 같다. 같은 책을 두 번 눌러도 한 번만 찍힌다.
--
-- 【알림은 처음 찍을 때만】 취소했다가 다시 찍어도 같은 알림이 또 가지 않게, 새로 들어간 줄이 있을 때만 보낸다.
--   취소하면 도장이 사라지고 알림은 보내지 않는다. 종류는 'friends'(108)라 끌 수 있다.
--
-- 【누가 찍나】 그 루틴의 승인된 참여자나 끗짱 본인. 남의 완독은 찍을 수 없다.
--
-- ⚠️ 23(visible_routine_ids) · 108(notify_push 종류) 뒤에 돌린다.

CREATE TABLE IF NOT EXISTS book_finishes (
  user_id     uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  routine_id  bigint NOT NULL REFERENCES routines(id) ON DELETE CASCADE,
  book_key    text   NOT NULL,
  book_title  text   NOT NULL,
  finished_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, routine_id, book_key)
);
CREATE INDEX IF NOT EXISTS book_finishes_routine_idx ON book_finishes(routine_id);

ALTER TABLE book_finishes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS finishes_read ON book_finishes;
-- 내 것과, 내가 볼 수 있는 루틴의 것(친구들의 도장). 쓰기는 함수로만 한다
CREATE POLICY finishes_read ON book_finishes FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR is_admin() OR routine_id IN (SELECT visible_routine_ids()));

-- ── 도장 찍기 ──────────────────────────────────────────
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
      PERFORM notify_push(u, '책을 완독했어요 🎉',
        COALESCE(v_title, '루틴') || ' · ' || COALESCE(v_who, '친구') || ' · 『' || left(btrim(p_title), 40) || '』',
        '/youthit-book/app.html?tab=cert&routine=' || p_routine, 'friends');
    END LOOP;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION finish_book(bigint, text, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION finish_book(bigint, text, text) TO authenticated;

-- ── 도장 취소 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION unfinish_book(p_routine bigint, p_key text)
RETURNS void AS $$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  DELETE FROM book_finishes WHERE user_id = auth.uid() AND routine_id = p_routine AND book_key = left(p_key, 120);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION unfinish_book(bigint, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION unfinish_book(bigint, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 알림을 보내지 않는다. 기대: 표 1, 정책 1, 함수 둘 다 1, 칸 6
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_name = 'book_finishes')     AS 표_1이어야,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'book_finishes')                    AS 정책_1이어야,
       (SELECT count(*) FROM pg_proc WHERE proname = 'finish_book')                            AS 찍기함수_1,
       (SELECT count(*) FROM pg_proc WHERE proname = 'unfinish_book')                          AS 취소함수_1,
       (SELECT count(*) FROM information_schema.columns WHERE table_name = 'book_finishes')    AS 칸_6이어야;
