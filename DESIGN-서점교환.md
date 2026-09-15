# 서점 교환 구조 (설계만, 아직 안 만듦)

**언제 만드나** — 파트너 서점이 10곳을 넘고 교환이 월 수십 건이 될 때.
그전까지는 관리자가 영수증 보고 금액 넣는 지금 방식이 더 빠르다.

**목표** — 서점이 확인하는 순간 포인트가 차감되고, 유스보이스에 정산 청구가
자동으로 쌓이는 것. **돈이 자동 이체되는 것은 목표가 아니다** (펌뱅킹/PG는
월 몇십만원 규모에 과하다). 월말에 서점별 금액만 보고 이체하면 되는 상태까지.

---

## 흐름

```
청소년 앱                서점 (store.html)              유스보이스
─────────               ──────────────────              ─────────
[교환권 사용하기]
      ↓
  6자리 코드 표시  ──보여줌──→  코드 입력 (로그인 없음)
   (10분 유효)                        ↓
                              ┌──────────────────┐
                              │ 유스끗짱 님        │
                              │ 한도 20,000원      │
                              │ 책방   [ 드롭다운 ] │
                              │ 책 제목 [        ] │
                              │ 금액    [        ] │
                              │   [ 교환 완료 ]    │
                              └──────────────────┘
                                        ↓
                        교환권 차감 + book_purchases 생성 + FIFO 차감
                                                            ↓
                                                    서점별 월간 청구서
                                                    → 이체는 사람이
```

**서점에 로그인을 시키지 않는다.** 책방은 바쁘고, 계정 만들기에서 다 떨어져
나간다. 북마크 하나 열고 숫자 두 개 넣으면 끝나야 한다.

QR보다 **6자리 코드**를 먼저. QR은 화면 밝기·조명 때문에 현장에서 애먹는다.

---

## '책 샀어요'가 둘로 쪼개진다

지금은 청소년이 돈 관련 일을 한다 — 책방 고르고, 영수증 챙기고, 금액 정산을
기다린다. **그건 아이가 할 일이 아니다.** 서점 확인 구조가 되면 이렇게 갈린다.

| | 누가 | 무엇을 |
|---|---|---|
| **돈** | 서점 | 코드 확인 · 금액 입력 → 자동 차감·정산 |
| **기록** | 청소년 | 책 받은 사진 · 책인증후기(30P) |

서점이 교환을 확정하면 **청소년 앱에 "책 받았어요"가 뜬다.**

```
서점이 [교환 완료]
        ↓
청소년 앱:  📚 책을 받았어요!
            [ 책 사진 찍기 ]      ← 얼굴은 책으로 가리고
            [ 이 책 어땠어? ]     ← 책인증후기 30P
```

- **서점이 아이 사진을 찍게 하지 않는다.** 서점 부담이고 아이 동의 문제가 걸린다.
  사진은 아이가 자기 폰으로, 자기 때에.
- **교환 직후에 사진을 강요하지 않는다.** 서점이 확정하자마자 "사진 찍으세요"가
  뜨면 사장님 앞에서 찍게 된다. `책 받았어요`는 **밀린 할 일**로 남겨두고
  (홈·인증 탭에 "받은 책 사진을 아직 안 올렸어요"), 집에 가서 편할 때 찍게 한다.
  사진의 질도 그편이 낫다 — 계산대 앞보다 자기 방에서 찍은 게 후원자에게도 좋다.
- 사진 공개 동의와 운영진 승인은 **지금 구조 그대로** 둔다.
- 영수증 사진(`dokseo-proofs`)은 이 경로에서는 필요 없어진다.

### ⚠️ 수기 경로는 지우지 말 것

서점 사장님이 자리에 없거나, 인터넷이 안 되거나, 코드가 만료되는 일이 반드시
생긴다.

- **기본** — 서점이 확인
- **예외** — 청소년이 영수증 사진 올리고 관리자가 수기 정산 (지금 그대로)

이미 만들어져 있으니 지우지 않고 두기만 하면 된다.

---

## DB

```sql
CREATE TABLE redemptions (
  id           bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  code         text   NOT NULL UNIQUE,          -- 6자리 숫자
  user_id      uuid   NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  routine_id   bigint REFERENCES routines(id) ON DELETE SET NULL,
  status       text   NOT NULL DEFAULT 'issued'
               CHECK (status IN ('issued','used','expired','void')),
  max_amount   int    NOT NULL,                 -- 발급 시점 한도를 굳힌다
  fail_count   int    NOT NULL DEFAULT 0,       -- 무작위 대입 방어
  bookstore_id bigint REFERENCES bookstores(id),
  book_title   text,
  amount       int,
  purchase_id  bigint REFERENCES book_purchases(id),
  issued_at    timestamptz DEFAULT now(),
  expires_at   timestamptz NOT NULL,
  used_at      timestamptz
);
CREATE INDEX ON redemptions (user_id, status);
```

### 굳혀야 할 값
- `max_amount` — 설정(`voucher_max_amount`)이 나중에 바뀌어도 그 코드의 한도는
  발급 시점 값을 지킨다. 루틴 단가를 굳히는 것과 같은 이유.

### ⚠️ 발급 즉시 교환권을 잡아둘 것
`dokseo_points()` 의 `used` 계산에 **`issued` 상태 코드도 포함**해야 한다.
안 그러면 코드를 여러 개 뽑아 여러 서점에서 동시에 쓸 수 있다.

```sql
-- 지금:   status IN ('pending','settled') 인 book_purchases 수
-- 바꾼 뒤: 위 + status = 'issued' 이고 안 만료된 redemptions 수
```

---

## 함수 (둘 다 SECURITY DEFINER, anon 호출 허용)

서점 화면은 로그인이 없으므로 **테이블 직접 접근은 막고 이 두 함수로만** 움직인다.

### `redeem_issue()` — 청소년이 코드 발급
- `auth.uid()` 기준. 쓸 수 있는 교환권이 없으면 거부
- 6자리 코드 생성, 중복이면 재생성
- `expires_at = now() + 10분`
- 이미 `issued` 이고 안 만료된 코드가 있으면 **새로 만들지 말고 그걸 돌려준다**

### `redeem_lookup(code)` — 서점이 코드 조회
- 반환: 닉네임, `max_amount`, 남은 시간. **그 이상 주지 않는다**
- 없거나 만료면 실패. 실패해도 "없는 코드"인지 "만료"인지 구분해 알려줄 것
  (서점이 당황하지 않게)

### `redeem_confirm(code, bookstore_id, book_title, amount)` — 교환 확정
한 트랜잭션 안에서:
1. 코드가 `issued` 이고 안 만료됐는지
2. `amount <= max_amount` 인지
3. `book_purchases` 생성 (status `settled`, amount 확정)
4. **`settle_book_purchase()` 와 같은 FIFO 차감** — `charges` 에서 오래된 후원부터
5. 도서기금이 부족하면 **전체 롤백**하고 "도서기금이 부족합니다" 반환
6. `redemptions` 를 `used` 로, `purchase_id` 연결

→ 기존 `settle_book_purchase()` 의 차감 부분을 내부 함수로 빼서 둘이 같이 쓰면
중복이 안 생긴다.

---

## 보안 — 로그인이 없으니 코드가 곧 열쇠

| 위협 | 대책 |
|---|---|
| 코드 무작위 대입 | 유효시간 **10분**, 동시에 유효한 코드가 몇 개뿐 |
| 그래도 뚫으면 | 코드별 **실패 5회면 폐기**(`fail_count`) |
| 뚫려도 피해 제한 | 금액 상한 **2만원**, 1회용 |
| 캡처해서 나중에 사용 | 유효시간 10분 |
| 개인정보 노출 | 조회로 나가는 건 **닉네임과 한도뿐**. 실명·이메일·기록 없음 |

6자리 숫자로 부족하다고 판단되면 **8자리 영숫자**(헷갈리는 `0 O 1 I L` 제외)로
올린다. 손 입력 부담은 늘지만 경우의 수가 폭증한다.

---

## 관리자 화면에 추가할 것

**서점별 월간 청구서** 탭 하나.

```sql
SELECT b.name, date_trunc('month', p.settled_at) AS 월,
       count(*) AS 권수, sum(p.amount) AS 지급액
  FROM book_purchases p JOIN bookstores b ON b.id = p.bookstore_id
 WHERE p.status = 'settled'
 GROUP BY b.name, 2 ORDER BY 2 DESC, b.name;
```

이 표를 보고 이체하면 끝. 이체 여부를 기록하려면 `paid_at` 컬럼을 하나 두면 된다.

---

## ⚠️ 같이 바꿔야 할 문구

지금 후원자 화면이 이렇게 약속하고 있다.

> 추정이 아니라, **책방 영수증으로 확인된 금액**만 차감합니다.

서점이 앱에서 직접 입력하는 방식이 되면 **영수증이 사라진다.** 신뢰의 근거가
바뀌는 것이므로 문구도 바꿔야 한다.

> 추정이 아니라, **책방이 직접 확인한 금액**만 차감합니다.

`sponsor.html` 의 `sec-lead` 와 정산 단계 설명 두 곳.

---

## 만들 때 순서

1. `redemptions` 테이블 + 세 함수 (마이그레이션 한 개)
2. `dokseo_points()` 의 `used` 에 `issued` 코드 포함
3. 청소년 앱 — `책 샀어요` 를 `교환권 쓰기`로. 코드와 남은 시간 표시
   (지금의 `책 샀어요`는 '영수증으로 신청' 예외 경로로 남긴다)
4. `store.html` — 한 장짜리. 코드 입력 → 확인 → 완료
5. 청소년 앱 — 교환이 확정되면 `책 받았어요` (사진 + 책인증후기 30P)
6. 관리자 — 서점별 월간 청구서 탭
7. 후원자 문구 수정

반나절 정도. 기존 `book_purchases` 흐름은 그대로 두고 옆에 붙이는 구조라
지금 돌아가는 것을 건드리지 않는다.
