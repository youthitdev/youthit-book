-- 한끗독서 마이그레이션 161
-- 끗짱 신청서가 없는데 「청소년 확인」 명단에 남아 있는 어른·끗짱 희망자를 끗짱 승인 대기로 옮긴다 (2026-11-11 QA)
--
-- 【왜】 관리자의 「청소년 확인」 명단은 끗짱 신청서가 있는 사람을 빼고 보여 준다. 그런데 가입할 때 끗짱을 골랐거나 만 20세를 넘은 사람 중에
--   가입 함수가 신청서를 만들어 주기 전(132 판이 돌기 전)에 들어온 사람은 신청서가 없어서 청소년 명단에 그대로 남아 있었다.
--   가입 함수는 이미 새 판이라(157·158·160) 지금부터 가입하는 끗짱은 문제가 없다. 여기서는 이미 남아 있는 사람만 정리한다.
--
-- 【하는 일】 132 의 「이미 가입해 있는 사람」 단계를 다시 돌린다.
--   · 가입할 때 끗짱을 골랐거나, 만 20세를 넘은 청소년 회원 중 신청서가 없는 사람에게 끗짱 신청서(심사 대기)를 만든다.
--   · 운영진에게 「끗짱 신청이 들어왔어요」 알림이 만든 수만큼 간다.
--   · 만 20세 이하이면서 끗짱을 고르지 않은 청소년은 건드리지 않는다. 운영진 계정·탈퇴한 회원도 뺀다.
--
-- ⚠️ 132·157 뒤에 돌린다. 여러 번 돌려도 된다(이미 신청서가 있는 사람은 건너뛴다).

WITH ins AS (
  INSERT INTO kkut_applications (user_id, age, affiliation, region, contact, intro, motive, status, applied_at)
  SELECT p.id, age_years(pp.birth_date),
         COALESCE(NULLIF(btrim(p.school_status), ''), '없음'),
         COALESCE(NULLIF(btrim(p.region), ''), '미상'),
         COALESCE(NULLIF(btrim(pp.phone), ''), '운영진이 따로 확인'),
         '가입할 때 끗짱을 골랐거나 만 20세를 넘어 자동으로 올라왔어요',
         '가입 시 자동으로 올라온 신청이에요', 'pending', now()
    FROM profiles p
    JOIN profiles_private pp ON pp.id = p.id
    JOIN auth.users u ON u.id = p.id
   WHERE COALESCE(p.role, 'youth') = 'youth'
     AND NOT COALESCE(p.can_lead, false)
     AND p.withdrawn_at IS NULL
     AND p.name <> '탈퇴한 회원'
     AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id)
     AND NOT EXISTS (SELECT 1 FROM kkut_applications k WHERE k.user_id = p.id)
     AND age_years(pp.birth_date) BETWEEN 14 AND 100
     AND (u.raw_user_meta_data->>'join_role' = 'kkut' OR age_years(pp.birth_date) > 20)
  ON CONFLICT (user_id) DO NOTHING
  RETURNING 1
)
SELECT count(*) AS 새로_만든_끗짱_신청서 FROM ins;

NOTIFY pgrst, 'reload schema';

-- ── 확인 ───────────────────────────────────────────────
-- 기대: 아래 「남은 끗짱·어른」은 0 (청소년 명단에 끗짱 희망자가 안 남았다). 생년월일이 없는 회원은 나이를 몰라 여기서 못 옮긴다
SELECT (SELECT count(*) FROM kkut_applications WHERE status = 'pending') AS 끗짱_심사_대기,
       (SELECT count(*) FROM profiles p
          JOIN profiles_private pp ON pp.id = p.id
          JOIN auth.users u ON u.id = p.id
         WHERE COALESCE(p.role, 'youth') = 'youth' AND NOT COALESCE(p.can_lead, false)
           AND p.withdrawn_at IS NULL AND p.name <> '탈퇴한 회원'
           AND age_years(pp.birth_date) BETWEEN 14 AND 100
           AND (u.raw_user_meta_data->>'join_role' = 'kkut' OR age_years(pp.birth_date) > 20)
           AND NOT EXISTS (SELECT 1 FROM kkut_applications k WHERE k.user_id = p.id)
           AND NOT EXISTS (SELECT 1 FROM admin_user_ids() a WHERE a = p.id))     AS 남은_끗짱_어른_0이어야;
