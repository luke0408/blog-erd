# 이벤트 전달과 중복 처리 방지

관련 구조: [OutboxEvent](../erd.md#outbox_events), [EventReceipt](../erd.md#event_receipts). 이벤트 본문 구조와 종류별 계약은 [JSON 데이터 계약](data-contracts.md#outbox-payload)을 참조한다.

## 이벤트와 정본

정본은 콘텐츠 메타데이터·스냅샷·Report다. 이벤트로 전체 도메인을 재구축하지 않는다.
내부 전달은 MySQL transactional outbox와 polling worker를 사용하며 MQ에 의존하지 않는다.

이벤트 종류·작업 주체·대상과 본문의 허용 필드는 [JSON 계약](data-contracts.md#outbox-payload)을 따른다.
aggregateVersion은 메타데이터 버전의 투영이다. 버전 없는 방문·조회 활동은 NULL을 사용한다.
(aggregateKey, aggregateVersion) UNIQUE로 같은 정본 버전의 중복 이벤트를 막는다.

## 전달과 중복 효과 방지

1. 정본 변경 또는 신고 수락과 OutboxEvent를 같은 짧은 트랜잭션에 저장한다.
2. 워커가 FOR UPDATE SKIP LOCKED로 claim하고 새 leaseToken과 leaseUntil을 저장한다.
3. 소비자가 이벤트 종류·계약·논리 키를 검증하고 효과 처리에 필요한 행을 잠근다.
4. 효과 트랜잭션에서 현재 leaseToken과 만료를 다시 확인한다.
5. EventReceipt를 중복 없이 삽입하고 새 영수증일 때만 DB 효과를 적용한다.
6. 영수증과 효과를 함께 커밋한다. lease가 바뀐 워커의 쓰기는 거부한다.
7. 필요한 소비자별 효과가 모두 완료되면 같은 lease 조건으로 processedAt을 기록한다.

영수증만 먼저 커밋하거나 수신만으로 완료 처리하지 않는다.
실패는 backoff·재시도 한도로 관리하고 입력 오류·대상 부재·계약 불일치는 보류한다.
같은 eventId의 다른 본문은 성공으로 재사용하지 않고 충돌로 거부한다.

## 순서와 외부 효과

신고 소비자는 도착 순서 대신 현재 Report 상태를 집계한다.
과거 이벤트로 최신 포인터를 되돌리거나 DELETED 콘텐츠를 복구하지 않는다.
버전 기반 projection은 이미 적용한 aggregateVersion보다 오래된 이벤트를 무시한다.

발생 시각 occurredAt과 전달 시각은 구분한다. 성공 활동 시 User.lastSeenAt을 갱신한다.
외부 네트워크 대기는 DB 트랜잭션 밖에서 수행한다.
외부 효과는 안정적인 멱등 키와 결과 대조를 사용하며 DB 영수증만으로 exactly-once를 보장하지 않는다.

## 복합 키와 원자성

(consumer, eventId)가 복합 PK다. 소비자마다 같은 이벤트의 DB 효과를 한 번만 적용한다.
외부 이벤트도 수용하므로 eventId는 FK가 아닌 논리 키다.

1. 효과 처리 트랜잭션에서 현재 leaseToken과 만료를 검증한다.
2. 영수증을 중복 없이 삽입한다. 이미 있으면 DB 효과를 생략한다.
3. 새 영수증과 DB 효과를 같은 트랜잭션에서 커밋한다.

UPDATE·DELETE는 금지한다.
외부 네트워크 효과는 이 영수증만으로 중복을 막을 수 없으므로 외부 멱등 키와 결과 대조가 필요하다.

## 전달 상태 규칙

claim마다 새 UUID leaseToken과 leaseUntil을 함께 설정한다. 효과·ACK 쓰기는 현재 토큰 일치와 유효한 임대를 다시 검사한다. availableAt은 최초 전달·실패 후 bounded backoff의 기준이고 attempts는 0 이상 시도 수다. 한도 초과·계약 불일치·대상 부재는 격리하며 성공으로 표시하지 않는다.

processedAt은 필요한 소비자별 영수증과 효과가 모두 완료된 뒤 같은 lease 조건으로 기록한다. lastError는 민감정보를 제거한 실패 원인만 담는다. lease 만료·재claim·워커 중단 후에는 현재 영수증과 정본을 대조하고 오래된 워커의 쓰기를 거부한다.
