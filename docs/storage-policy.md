# MySQL 저장 정책

관련 구조: [데이터 모델](../erd.md). 공통 저장 규칙의 정본이며 테이블 정의는 ERD를 참조한다.

## MySQL 저장 규칙

| 데이터 | 저장 타입·규칙 |
| --- | --- |
| 전 테이블 | ENGINE=InnoDB · CHARSET=utf8mb4 · COLLATE=utf8mb4_general_ci |
| 증거·이미지·이벤트 | MySQL JSON, 내부 필드 계약은 서비스에서 검증 |
| UUID | CHAR(36), 서버/Prisma가 발급 |
| 시각 | DATETIME(3), UTC 저장·조회, DB 세션과 서비스의 시간대를 UTC로 통일 |
| 콘텐츠 본문 | LONGTEXT, 포스트 제목은 VARCHAR(200) |
| 브라우저 scope | JSON 배열, 정확히 [PREFERENCES]만 허용 |
| 논리 키·멱등 키 | 소문자 ASCII 정본으로 저장, 대소문자만 다른 값을 별도 키로 취급하지 않음 |

테이블·문자열 컬럼과 DB 연결의 문자셋·collation을 같은 기준으로 맞춰 1267 혼합정렬 오류를 방지한다.
JSON에서 추출한 문자열을 SQL에서 비교할 때도 utf8mb4_general_ci로 명시적으로 통일한다.
ENGINE·CHARSET·COLLATE는 Prisma 모델 속성으로 선언하지 못하는 DDL 규칙이다. 이 주석만으로 DB에 적용되지 않는다.

물리 FK를 생성하지 않는다. 존재·소유자·삭제 정책은 [관계 무결성 계약](relation-integrity.md)에 따라 서비스가 검증하며, 지연 제약으로 커밋 시 정본 완성을 검사하지 않는다.
서비스는 메타데이터 생성·스냅샷 삽입·최신 포인터 갱신을 한 트랜잭션에서 순서대로 수행한다.
커밋 전에 최소 스냅샷·최대 revision·관리 키를 확인하고 실패하면 전체를 롤백한다.

## 적용 경계

스키마 검증은 MySQL 문법·타입·관계를 검증할 뿐 DB에 접속하거나 DDL을 설치하지 않는다. `prisma/migrations/`의 PostgreSQL SQL과 provider 잠금은 현재 MySQL 스키마에 적용할 수 없다. 이를 MySQL DDL이 설치된 증거로 취급하지 않는다.

서비스 DB 계정에는 테이블 소유·TRUNCATE·DDL 권한을 부여하지 않는다. PK·UNIQUE·NOT NULL은 DB 제약이며, 논리 관계·JSON 내부 계약·불변성·상태 전이는 서비스 검증 책임이다. 운영 입력·삭제도 같은 관계 검증 계약을 적용한다.
