-- 한끗독서 마이그레이션 55
-- 청소년 확인 승인 알림에 이모지 하나
--
--   전:  청소년 확인이 끝났어요 ✅ / 이제 루틴에 참여할 수 있어요
--   후:  청소년 확인이 끝났어요 ✅ / 이제 루틴에 참여할 수 있어요 🌱
--
-- 제목의 ✅ 는 「끝났다」, 본문의 🌱 는 「이제 시작이다」. 두 줄이 하나씩 맡는다.
-- 📚 는 루틴 참여 승인 알림이 이미 쓰고 있어 겹치지 않게 뒀다.
--
-- ⚠️ 함수 전체를 다시 쓴다. 청소년 확인·반려·끗짱 승인이 한 함수에 들어 있어
--    한 줄만 고칠 수가 없다. 나머지 세 줄은 그대로다.

CREATE OR REPLACE FUNCTION on_profile_decided() RETURNS trigger AS $$
BEGIN
  IF NEW.verify_status IS DISTINCT FROM OLD.verify_status THEN
    IF NEW.verify_status = 'approved' THEN
      PERFORM notify_push(NEW.id, '청소년 확인이 끝났어요 ✅',
        '이제 루틴에 참여할 수 있어요 🌱', '/youthit-book/app.html?tab=home');
    ELSIF NEW.verify_status = 'rejected' THEN
      PERFORM notify_push(NEW.id, '서류를 다시 올려주세요',
        COALESCE(NEW.verify_reason, '확인이 어려웠어요'), '/youthit-book/app.html?tab=my');
    END IF;
  END IF;

  IF NEW.can_lead AND NOT OLD.can_lead THEN
    PERFORM notify_push(NEW.id, '끗짱이 되셨어요 💪',
      '이제 루틴을 만들 수 있어요', '/youthit-book/app.html?tab=home');
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 트리거는 그대로 붙어 있다. 함수만 갈렸으므로 다시 걸 필요는 없지만, 확인은 한다
SELECT tgname AS 트리거, c.relname AS 표, p.proname AS 함수
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc  p ON p.oid = t.tgfoid
 WHERE tgname = 'profiles_notify';
