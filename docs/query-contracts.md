# 목록·검색·정렬과 조회 계약

테이블·인덱스 선언의 정본은 [ERD](../erd.md)다. 이 문서는 어떤 조건으로 어떤 데이터를 조회하는지 정의한다.

## 목록·검색·정렬 규칙

- 모든 목록은 서버 페이지네이션을 적용하고 페이지 크기에 서버 상한을 둔다. 전체 행을 내려받아 클라이언트에서 자르지 않는다.
- 기본 페이지 방식은 keyset이다. 시각과 PK를 함께 정렬하고 같은 값을 커서에 포함해 동률 행의 누락·중복을 방지한다.
- 검색·필터·정렬 컬럼은 서버 허용 목록으로 제한하고 조건·정렬 순서에 맞는 인덱스를 함께 선언한다.
- SQL의 SELECT *는 금지한다. Prisma 조회도 select로 필요한 컬럼과 관계의 컬럼을 명시한다.
- 목록에는 필요한 요약만 조회한다. 신고 payload·review와 전체 콘텐츠 스냅샷은 권한 검증 후 필요한 조회에서만 읽는다.
- B-tree 인덱스로 임의 본문 부분 문자열 검색을 지원한다고 가정하지 않는다. 전용 검색 인덱스 없는 검색·정렬은 제공하지 않는다.

| 목록 | 필터·정렬 기준 | 인덱스 |
| --- | --- | --- |
| 포스트 | status, createdAt·id | (status, createdAt, id) |
| 포스트별 댓글 | postId, createdAt·id | (postId, createdAt, id) |
| 상태별 댓글 | postId·status, createdAt·id | (postId, status, createdAt, id) |
| 신고 검수 | status, createdAt·id | (status, createdAt, id) |
| 작성 세션별 신고 | targetAuthorKey, createdAt·id | (targetAuthorKey, createdAt, id) |

페이지네이션 전에 현재 노출 상태·개인 숨김·신고 임계값을 서버에서 적용한다. 클라이언트 후처리로 권한을 대신하지 않는다.

## 명시적 조회 컬럼

| 조회 | 필요한 컬럼·관계 | 제외·추가 조건 |
| --- | --- | --- |
| 포스트 목록 | id·status·createdAt, currentSnapshot의 id·revision·title | 관리 키 해시·전체 본문·이미지 배열은 목록에서 제외 |
| 댓글 목록 | id·postId·parentId·status·createdAt, 허용된 currentSnapshot의 id·revision·content | 숨긴 댓글은 본문 없이 자리표시자 |
| 신고 검수 목록 | id·targetType·targetId·targetAuthorKey·status·createdAt·reviewedAt | payload·review는 권한 있는 상세 조회에서 읽음 |
| 신고 증거 상세 | 신고 대상·투영 키·payload·status·review·검수 시각 | 별도 운영 인증과 대상 검수 권한 필요 |

위 컬럼은 SQL SELECT 또는 Prisma select에 명시한다. 관계 조회에도 select를 적용하며 컬럼 추가는 조회 계약과 인덱스 영향을 함께 검토한다. 공개 User 응답에는 sessionKey와 콘텐츠 관리 키 해시를 포함하지 않는다.

## 노출과 정본 조회

일반 콘텐츠 조회는 currentSnapshot만 사용하며 MAX(id)나 생성 시각으로 최신 정본을 추정하지 않는다. 숨김 판정은 [신고 설계](report-moderation.md)의 개인 숨김·현재 신고 임계값을 적용한다. 숨긴 포스트의 댓글·검색·개수·이미지도 차단한다. 과거 정본과 이미지는 검수자 또는 해당 콘텐츠 관리 키 권한자에게만 제공한다.

## 신고 조회 경로

대상별 집계는 (targetType, targetId, status), 논리 키별 집계는 (targetKey, status) 인덱스를 사용한다. 관리자 증거 상세는 reports만 조회하며 원본 삭제·수정 후에도 당시 증거를 읽는다. 필터를 변경하면 커서를 재사용하지 않으며 다음 페이지에도 같은 필터·정렬·노출 검사를 적용한다. 본문 LIKE 부분 검색을 B-tree 지원 검색으로 취급하지 않는다.
