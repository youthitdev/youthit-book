-- 테스트로 채워 넣은 인증만 지운다 (실제로 올린 인증은 남는다)
DELETE FROM certifications
 WHERE content = '[테스트] 채워 넣은 기록';
