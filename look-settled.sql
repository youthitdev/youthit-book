-- 정산됐다고 잡혀 있는 구매가 무엇인지 본다
-- 지우기 전에 **이것부터** 보세요. 진짜 돈이 나갔는지는 대표님만 아십니다.

SELECT g.id,
       r.title                              AS 루틴,
       COALESCE(pr.nick, pr.name, '(모름)')  AS 아이,
       s.name                               AS 책방,
       g.amount                             AS 금액,
       g.settled_at::date                   AS 정산한날,
       CASE WHEN g.paid_at IS NULL THEN '입금 대기'
            ELSE '입금 완료 ' || g.paid_at::date END AS 입금,
       g.note                               AS 메모
  FROM book_purchases g
  LEFT JOIN routines  r  ON r.id  = g.routine_id
  LEFT JOIN profiles  pr ON pr.id = g.user_id
  LEFT JOIN bookstores s ON s.id  = g.bookstore_id
 WHERE g.status = 'settled'
 ORDER BY g.settled_at;
