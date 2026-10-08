-- 한끗독서 마이그레이션 94
-- 루틴을 보러 온 아이에게 끗짱이 누구인지 보인다 (닉네임 + 키워드 세 개)
--
-- 【왜 필요한가】 상세 화면의 「이 루틴을 이끄는 끗짱」이 늘 「익명」이었다. 아이들의 닉네임은
--   같은 루틴 사람끼리만 읽히게 막아 두었는데, 아직 들어오기 전의 아이에게는 끗짱도 그 밖이다.
--   신청하러 들어온 아이가 제일 궁금한 건 「이 사람이 누구지?」다 (2026-10-08 사용자).
--
-- 【무엇을 보이나 — 닉네임과 키워드만】 실명·나이·지역·연락처·소속은 보이지 않는다.
--   소속은 끗짱이 신청서에 적은 것이라 아이에게 보이게 하지 않기로 했다. 대신 **자기를
--   나타내는 키워드 세 개**를 끗짱이 직접 고른다.
--
-- 【키워드를 신청서 칸에 두지 않는 이유】 check_kkut_application 트리거가 **승인된 신청서의
--   수정을 막는다.** 신청서 칸으로 두면 승인된 끗짱은 키워드를 못 적고 못 고친다.
--   SECURITY DEFINER 로 돌려도 auth.uid() 가 끗짱 본인이라 트리거가 그대로 막는다.
--   그래서 따로 표를 둔다.
--
-- 【이름은 함수로만 내보낸다】 profiles 는 같은 루틴 사람에게만 읽힌다. 그걸 풀지 않고
--   **보이는 루틴의 끗짱 한 줄**만 돌려주는 함수를 낸다. 익명(로그인 전)도 부를 수 있다.
--
-- ⚠️ 21(신청서) · 33(트리거) 뒤에 돌린다.

-- ── 1. 키워드 표 ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS kkut_keywords (
  user_id    uuid PRIMARY KEY REFERENCES auth.users ON DELETE CASCADE,
  keywords   text[] NOT NULL DEFAULT '{}' CHECK (cardinality(keywords) <= 3),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE kkut_keywords ENABLE ROW LEVEL SECURITY;
-- 본인은 자기 것을 읽고(내 정보에 채워 넣으려고), 운영진은 승인할 때 본다. 쓰기는 함수로만 한다
DROP POLICY IF EXISTS kkut_kw_self  ON kkut_keywords;
DROP POLICY IF EXISTS kkut_kw_admin ON kkut_keywords;
CREATE POLICY kkut_kw_self  ON kkut_keywords FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY kkut_kw_admin ON kkut_keywords FOR SELECT TO authenticated USING (is_admin());

-- ── 2. 다듬기 — 쓰는 사람마다 다르게 적어도 같은 모양으로 ──
-- 앞뒤 공백·# 을 걷고, 12자에서 자르고, 빈 것과 겹치는 것을 빼고, 앞에서부터 세 개
CREATE OR REPLACE FUNCTION clean_keywords(p_in text[]) RETURNS text[] AS $$
  SELECT COALESCE(array_agg(k ORDER BY ord), '{}'::text[])
    FROM (
      SELECT k, ord FROM (
        SELECT DISTINCT ON (k) k, ord FROM (
          SELECT btrim(left(btrim(replace(x, '#', '')), 12)) AS k, ord
            FROM unnest(COALESCE(p_in, '{}'::text[])) WITH ORDINALITY AS t(x, ord)
        ) a
        WHERE k <> ''
        ORDER BY k, ord
      ) d
      ORDER BY ord
      LIMIT 3
    ) e;
$$ LANGUAGE sql IMMUTABLE;

-- ── 3. 내 키워드를 적는다 ──────────────────────────────
-- 신청서가 있는 사람만 (끗짱이 되려는 사람, 끗짱). 아무나 이 표에 자리를 만들지 못하게
CREATE OR REPLACE FUNCTION set_my_keywords(p_keywords text[]) RETURNS text[] AS $$
DECLARE v_u uuid := auth.uid(); v_k text[];
BEGIN
  IF v_u IS NULL THEN RAISE EXCEPTION '로그인이 필요해요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM kkut_applications WHERE user_id = v_u) THEN
    RAISE EXCEPTION '끗짱 신청 뒤에 적을 수 있어요';
  END IF;

  v_k := clean_keywords(p_keywords);
  INSERT INTO kkut_keywords(user_id, keywords, updated_at) VALUES (v_u, v_k, now())
  ON CONFLICT (user_id) DO UPDATE SET keywords = EXCLUDED.keywords, updated_at = now();
  RETURN v_k;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
REVOKE EXECUTE ON FUNCTION set_my_keywords(text[]) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION set_my_keywords(text[]) TO authenticated;

-- ── 4. 보이는 루틴의 끗짱 ──────────────────────────────
-- 닉네임(없으면 이름)과 키워드. 아직 열리지 않은 루틴(pending)의 끗짱은 내보내지 않는다.
-- 승인된 끗짱만. 로그인 전 방문자도 부를 수 있다 — 공유 링크로 들어온 사람이 첫 독자다
CREATE OR REPLACE FUNCTION routine_leads()
RETURNS TABLE (user_id uuid, nick text, keywords text[]) AS $$
  SELECT p.id,
         COALESCE(NULLIF(btrim(p.nick), ''), NULLIF(btrim(p.name), '')),
         COALESCE(k.keywords, '{}'::text[])
    FROM profiles p
    LEFT JOIN kkut_keywords k ON k.user_id = p.id
   WHERE p.id IN (SELECT r.led_by FROM routines r
                   WHERE r.led_by IS NOT NULL AND r.status <> 'pending')
$$ LANGUAGE sql SECURITY DEFINER STABLE;
REVOKE EXECUTE ON FUNCTION routine_leads() FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION routine_leads() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 몸통이 실제로 도는지까지 본다. 다듬기는 일부러 지저분하게 넣어서 본다.
-- 기대: {책방지기,시집,"느린 독서 아주 길게"} — # 은 걷히고, 겹치는 「시집」은 하나, 빈 것은 빠지고,
--       12자를 넘는 건 잘리고(끝 공백도 걷힌다), 네 번째부터는 버려진다
SELECT clean_keywords(ARRAY['#책방지기 ', '시집', '시집', '', '느린 독서 아주 길게 써 놓은 말', '다섯째', '여섯째'])
         AS 다듬기_기대_세개,
       (SELECT count(*) FROM routine_leads())                       AS 보이는_끗짱수,
       (SELECT count(*) FROM pg_policies WHERE tablename = 'kkut_keywords') AS 정책_2여야;
