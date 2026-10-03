# Repository Guidelines

## Repository Purpose

이 저장소는 MySQL 기반 ERD 설계 연습용이다. 데이터의 저장·참조·복사 흐름과 상세 처리 계약을 구분한다. 회원 인증, CRUD API, 이벤트 워커 등이 실제 구현되었다고 가정하지 않는다.

## Project Structure

- `prisma/schema.prisma`: 테이블·컬럼·관계·키·인덱스와 데이터 흐름 요약의 정본이다.
- `prisma/migrations/`: 기존 PostgreSQL 마이그레이션을 보관한다. 현재 MySQL 스키마에 적용하거나 provider 잠금만 변경하지 않는다.
- `prisma.config.ts`: Prisma 설정과 환경 변수 로딩을 담당한다.
- `scripts/generate-erd.mjs`: `prisma-markdown` 기반 생성과 코드 블록 포맷을 담당한다. 필수 생성기만 Git에서 추적하고 나머지 `scripts/`는 제외한다. 설계 내용을 직접 보관하지 않는다.
- `erd.md`: 스키마에서 생성하는 데이터 모델 문서다. 수동 수정하지 않는다.
- `docs/`: 비즈니스 처리·저장 정책·조회 계약·JSON 내부 구조의 정본이다. `docs/README.md`에서 문서 책임을 확인한다.
- `generated/`, `node_modules/`: 로컬 생성물이며 Git에서 제외한다.

이 파일은 에이전트 작업 지침이며 설계 내용을 별도로 보관하는 문서가 아니다.

## Development Commands

Node.js 22.12+ 또는 24.x LTS와 npm을 사용한다. `npm ci`로 잠금 파일 기준 의존성을 설치한다. 검증 시 로컬용 `DATABASE_URL`을 환경 변수나 Git에서 제외된 `.env`에 설정한다.

- `npm run schema:format`: Prisma 스키마를 포맷한다.
- `npm run schema:validate`: 문법과 관계를 검증한다. 실행 중인 DB는 필요하지 않다.
- `npm run erd:build`: 루트 `erd.md`만 재생성한다.
- `npm run db:generate`: Prisma Client와 `erd.md`를 생성한다.
- `npm run dev`: ERD를 한 번 생성한다. 서버나 watcher는 실행하지 않는다.
- `npm run db:migrate`, `npm run db:studio`: 설정된 로컬 DB에 접속한다. 운영 DB에 실행하지 않는다.

## Style And Documentation

모델은 PascalCase, Prisma 필드는 camelCase, DB 테이블과 컬럼은 `@@map`/`@map`으로 snake_case를 사용한다. 들여쓰기는 2칸이며 최종 형식은 Prisma formatter를 따른다.

모델·필드 설명은 한글 `///` 주석으로 작성한다. 예제처럼 `@namespace`로 영역을 분리하고 `@erd`로 그림에만 관련 모델을 포함한다. 내부 참조는 `{@link users.id 비회원 방문}`처럼 생성 문서의 테이블 이름을 사용한다. 최소 스냅샷 관계는 `@minItems 1`로 표현하되 실제 DB 제약도 함께 확인한다.

ERD에는 저장 위치·참조 관계·증거 복사·핵심 불변식과 강제 주체를 남긴다. 물리 FK는 사용하지 않고 `relationMode = "prisma"`와 `@relation`으로 논리 관계를 표현한다. 참조 인덱스는 명시적으로 선언하고 관계 존재·소유자·삭제 정책은 서비스가 검증한다. 관계선이나 컬럼 표기를 물리 FK로 설명하지 않는다. JSON Schema·실제 JSON 예시·권한·상태 전이·트랜잭션·재시도·조회 계약은 `docs/`에만 작성한다. 스키마 주석의 상세 문서 링크는 루트 `erd.md` 기준 `docs/...` 경로를 사용하고, `docs/`에서는 `../erd.md#reports`처럼 참조한다. 선택·작업·검증 이력을 설계 본문에 넣지 않는다.

## Validation

별도 테스트 러너와 커버리지 기준은 없다. 변경 후 MySQL 형식의 검증용 `DATABASE_URL`로 format, validate, erd:build를 실행하고 관계 방향, 필수/선택 관계, 복합 키, 문서 링크와 JSON 계약을 확인한다. 스키마 검증·문서 생성에는 DB 접속이 필요하지 않다. SQL 변경은 사용자 요청이 있을 때 disposable MySQL에서 별도로 검증하며 기존 마이그레이션을 재작성하지 않는다. `prisma db push`는 사용자 정의 제약을 설치하지 않으므로 대체 수단으로 사용하지 않는다. 스키마 검증과 실제 DB/API 검증 결과를 구분한다.

## Git Workflow And Safety

초기 Git 이력은 없으므로 제공된 규칙을 따른다. 커밋은 `type(scope): subject`, 현재시제·소문자 시작·마침표 없음·72자 이내로 작성한다. 예: `docs(erd): document guest session boundaries`. 기능은 `develop`에서 `feat/*`, 긴급 수정은 `main`에서 `hotfix/*`로 분기한다. PR에는 목적, 변경, 검증 결과, 영향과 롤백 방법을 기록하고 최소 1명 승인을 받는다.

기존 사용자 변경과 `AGENTS.md`를 임의로 덮어쓰지 않는다. 비밀 정보와 실제 사용자 데이터를 커밋하지 않는다. push, 배포, 릴리스, 운영 설정 변경과 재시작은 현재 요청의 명시적 승인이 필요하다.
