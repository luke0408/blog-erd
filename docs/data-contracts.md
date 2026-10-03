# JSON 데이터 계약

테이블·컬럼·관계는 [ERD](../erd.md)가 정본이다. 아래 계약은 MySQL JSON 내부 구조의 정본이며 서비스가 검증한다. Prisma Json 선언은 내부 필드 계약이나 교차 필드 일치를 실행하지 않는다.

## 대상과 투영 키

Report의 대상·증거 키에는 Post·Comment·User·Snapshot에 대한 Prisma relation이 없다. 물리 FK는 전체 테이블에 사용하지 않으며, 일반 참조와 역사적 증거의 차이는 [관계 무결성](relation-integrity.md)을 따른다.
같은 숫자 ID라도 POST와 COMMENT는 서로 다른 신고 대상이다.

| 컬럼 | 기준 |
| --- | --- |
| targetType | POST 또는 COMMENT, JSON target.kind와 일치 |
| targetId | 종류별 양수 리소스 ID, JSON target.resourceId와 일치 |
| targetAuthorKey | 당시 최초 작성 세션의 필수 논리 키 |
| targetKey | `post:<id>` 또는 `comment:<id>`, 대상 컬럼과 일치 |
| reporterKey | 신고 세션 `user:<id>`, JSON actor.userId와 일치 |
| snapshotKey | 종류별 스냅샷 논리 키, JSON target.snapshotId와 일치 |
| eventId | 요청 재시도 멱등 키, UNIQUE |

서비스는 JSON과 투영 키의 일치를 검사한다. Prisma Json 선언이나 MySQL JSON 타입만으로 보장하지 않는다.
실제 대상·권한·정본 내용·조회 증표 검증은 신고 수락 서비스의 책임이다.

## Report Payload

신고 증거는 아래 단일 계약을 따르는 JSON 객체다.

| 경로 | 값·제약 |
| --- | --- |
| actor.userId | 양수 정수인 신고 세션 ID |
| target.kind | POST 또는 COMMENT |
| target.resourceId | 대상 ID |
| target.snapshotId | 양수 정수인 관찰 스냅샷 ID |
| target.revision | 양수 정수인 관찰 개정 번호 |
| target.authorKey | 최초 작성 세션 `user:<id>` |
| snapshot | 해당 종류의 전체 정본 복사본 |
| reason.detail | 공백만으로 구성되지 않은 1~500자 사유 |

### 종류별 스냅샷

| 구분 | 필수 속성 | 금지 속성 |
| --- | --- | --- |
| 공통 | id, revision, content, created_at, editor_key | 토큰·관리 키·원본 IP |
| POST | post_id, title, images | comment_id |
| COMMENT | comment_id | post_id, title, images |

스냅샷의 id·revision·소유 ID는 target과 일치해야 한다.
editor_key는 실제 작성·수정 세션 `user:<id>`이며 필수다.
POST images의 JSON 계약은 [이미지 메타데이터](#images)와 같다.

target.kind가 다형성 타입 식별자다. 서비스는 종류별 타입 계약으로 파싱하고 모르는 종류나 혼합된 전용 필드를 거부한다.
Prisma Json 타입이나 targetType 컬럼만으로 애플리케이션 타입 안전성이 보장되지는 않는다.

저장된 증거를 이후의 본문으로 덮어쓰지 않는다.

### JSON Schema

아래 JSON Schema는 저장할 증거의 형태 계약이다. 필수 값의 NULL과 정의되지 않은 속성은 허용하지 않는다.
형식 검사는 서비스의 책임이며 Prisma Json 선언만으로 이 계약이 실행되지는 않는다.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "ReportPayload",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "actor",
    "target",
    "snapshot",
    "reason"
  ],
  "properties": {
    "actor": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "userId"
      ],
      "properties": {
        "userId": {
          "$ref": "#/definitions/id"
        }
      }
    },
    "target": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "resourceId",
        "snapshotId",
        "revision",
        "authorKey"
      ],
      "properties": {
        "kind": {
          "enum": [
            "POST",
            "COMMENT"
          ]
        },
        "resourceId": {
          "$ref": "#/definitions/id"
        },
        "snapshotId": {
          "$ref": "#/definitions/id"
        },
        "revision": {
          "$ref": "#/definitions/id"
        },
        "authorKey": {
          "$ref": "#/definitions/userKey"
        }
      }
    },
    "snapshot": {
      "type": "object"
    },
    "reason": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "detail"
      ],
      "properties": {
        "detail": {
          "type": "string",
          "minLength": 1,
          "maxLength": 500,
          "pattern": "\\S"
        }
      }
    }
  },
  "oneOf": [
    {
      "properties": {
        "target": {
          "properties": {
            "kind": {
              "const": "POST"
            }
          }
        },
        "snapshot": {
          "$ref": "#/definitions/postSnapshot"
        }
      }
    },
    {
      "properties": {
        "target": {
          "properties": {
            "kind": {
              "const": "COMMENT"
            }
          }
        },
        "snapshot": {
          "$ref": "#/definitions/commentSnapshot"
        }
      }
    }
  ],
  "definitions": {
    "id": {
      "type": "integer",
      "minimum": 1,
      "maximum": 2147483647
    },
    "userKey": {
      "type": "string",
      "pattern": "^user:[1-9][0-9]*$"
    },
    "postSnapshot": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "post_id",
        "revision",
        "title",
        "content",
        "images",
        "created_at",
        "editor_key"
      ],
      "properties": {
        "id": {
          "$ref": "#/definitions/id"
        },
        "post_id": {
          "$ref": "#/definitions/id"
        },
        "revision": {
          "$ref": "#/definitions/id"
        },
        "title": {
          "type": "string",
          "maxLength": 200
        },
        "content": {
          "type": "string"
        },
        "images": {
          "type": "array",
          "maxItems": 10,
          "items": {
            "$ref": "#/definitions/image"
          }
        },
        "created_at": {
          "type": "string",
          "format": "date-time"
        },
        "editor_key": {
          "$ref": "#/definitions/userKey"
        }
      }
    },
    "commentSnapshot": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "comment_id",
        "revision",
        "content",
        "created_at",
        "editor_key"
      ],
      "properties": {
        "id": {
          "$ref": "#/definitions/id"
        },
        "comment_id": {
          "$ref": "#/definitions/id"
        },
        "revision": {
          "$ref": "#/definitions/id"
        },
        "content": {
          "type": "string"
        },
        "created_at": {
          "type": "string",
          "format": "date-time"
        },
        "editor_key": {
          "$ref": "#/definitions/userKey"
        }
      }
    },
    "image": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "storageKey",
        "objectVersion",
        "sha256",
        "mimeType",
        "bytes",
        "width",
        "height"
      ],
      "properties": {
        "storageKey": {
          "type": "string",
          "minLength": 1
        },
        "objectVersion": {
          "type": "string",
          "minLength": 1
        },
        "sha256": {
          "type": "string",
          "pattern": "^[0-9a-f]{64}$"
        },
        "mimeType": {
          "enum": [
            "image/jpeg",
            "image/png",
            "image/webp"
          ]
        },
        "bytes": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10485760
        },
        "width": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10000
        },
        "height": {
          "type": "integer",
          "minimum": 1,
          "maximum": 10000
        },
        "alt": {
          "type": "string"
        }
      }
    }
  }
}
```

JSON Schema의 형태 검사와 별도로 다음 정합성을 검증한다.

| 비교 | 일치 기준 |
| --- | --- |
| actor.userId ↔ reporterKey | `user:<actor.userId>` |
| target.kind·resourceId ↔ 대상 컬럼 | targetType·targetId·targetKey와 같은 대상 |
| target.authorKey ↔ targetAuthorKey | 관찰 정본 소유 콘텐츠의 최초 authorId |
| target.snapshotId ↔ snapshot.id·snapshotKey | 같은 관찰 정본 |
| target.revision ↔ snapshot.revision | 같은 개정 번호 |
| target.resourceId ↔ snapshot.post_id/comment_id | 종류별 정본 소유자 |
| snapshot ↔ 관찰 정본 | 서버 정본의 제목·본문·이미지·수정자·시각과 일치 |

## Outbox Payload

이벤트 본문은 논리 키만 전달하며 콘텐츠 본문과 신고 증거를 중복 저장하지 않는다.
eventType·aggregateKey·aggregateVersion·occurredAt은 컬럼이 정본이므로 payload에 반복하지 않는다.
actor는 실제 작업 주체다. 운영 검수자와 시스템을 비회원 User로 표현하지 않는다.

| 경로 | 타입·필수 여부 | 계약 |
| --- | --- | --- |
| actor.kind | 문자열, 필수 | GUEST / OPERATOR / SYSTEM |
| actor.key | 문자열, 필수 | 종류별 `user:<id>` / `operator:<id>` / `system:<name>` |
| target.kind | 문자열, 필수 | USER / POST / COMMENT / REPORT |
| target.resourceId | 양수 정수, 필수 | aggregateKey가 가리키는 정본 ID |
| snapshotKey | 문자열, 콘텐츠·신고 이벤트 필수 | 관찰 또는 변경 결과 스냅샷의 논리 키 |

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "OutboxPayload",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "actor",
    "target"
  ],
  "properties": {
    "actor": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "key"
      ],
      "properties": {
        "kind": {
          "enum": [
            "GUEST",
            "OPERATOR",
            "SYSTEM"
          ]
        },
        "key": {
          "type": "string"
        }
      },
      "oneOf": [
        {
          "properties": {
            "kind": {
              "const": "GUEST"
            },
            "key": {
              "pattern": "^user:[1-9][0-9]*$"
            }
          }
        },
        {
          "properties": {
            "kind": {
              "const": "OPERATOR"
            },
            "key": {
              "pattern": "^operator:[a-z0-9_-]+$"
            }
          }
        },
        {
          "properties": {
            "kind": {
              "const": "SYSTEM"
            },
            "key": {
              "pattern": "^system:[a-z0-9_-]+$"
            }
          }
        }
      ]
    },
    "target": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "resourceId"
      ],
      "properties": {
        "kind": {
          "enum": [
            "USER",
            "POST",
            "COMMENT",
            "REPORT"
          ]
        },
        "resourceId": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2147483647
        }
      }
    },
    "snapshotKey": {
      "type": "string",
      "pattern": "^(post|comment)-snapshot:[1-9][0-9]*$"
    }
  },
  "oneOf": [
    {
      "properties": {
        "target": {
          "properties": {
            "kind": {
              "const": "USER"
            }
          }
        }
      },
      "not": {
        "required": [
          "snapshotKey"
        ]
      }
    },
    {
      "required": [
        "snapshotKey"
      ],
      "properties": {
        "target": {
          "properties": {
            "kind": {
              "const": "POST"
            }
          }
        },
        "snapshotKey": {
          "pattern": "^post-snapshot:[1-9][0-9]*$"
        }
      }
    },
    {
      "required": [
        "snapshotKey"
      ],
      "properties": {
        "target": {
          "properties": {
            "kind": {
              "const": "COMMENT"
            }
          }
        },
        "snapshotKey": {
          "pattern": "^comment-snapshot:[1-9][0-9]*$"
        }
      }
    },
    {
      "required": [
        "snapshotKey"
      ],
      "properties": {
        "target": {
          "properties": {
            "kind": {
              "const": "REPORT"
            }
          }
        }
      }
    }
  ]
}
```

서비스는 공통 형태 검사에 더해 eventType별 다음 조건을 검증한다.

| eventType | actor.kind | target.kind | aggregateVersion | snapshotKey |
| --- | --- | --- | --- | --- |
| GuestVisitStarted | GUEST | USER | NULL | 없음, actor.key와 aggregateKey가 같은 방문 |
| ContentViewed | GUEST | POST / COMMENT | NULL | 실제 관찰 정본 |
| PostCreated / PostUpdated / PostDeleted | GUEST | POST | 변경 후 Post.version | 해당 변경의 최신 정본 |
| CommentCreated / CommentUpdated / CommentDeleted | GUEST | COMMENT | 변경 후 Comment.version | 해당 변경의 최신 정본 |
| ReportAccepted | GUEST | REPORT | Report.version | Report.snapshotKey, actor.key=reporterKey |
| ReportReviewed | OPERATOR | REPORT | 검수 후 Report.version | Report.snapshotKey |
| ContentModerationChanged | OPERATOR / SYSTEM | POST / COMMENT | 변경 후 콘텐츠 version | 해당 변경의 최신 정본 |

aggregateKey는 target.kind의 소문자 접두사와 resourceId로 구성한다.
REPORT의 snapshotKey는 신고 대상의 정본이며 Report 자체의 스냅샷을 뜻하지 않는다.
actor.key는 인증된 작업 주체로부터 서버가 구성한다. 키 문자열만으로 권한을 인정하지 않는다.
콘텐츠·검수 소비자는 논리 키로 현재 정본을 읽으며 이벤트 도착 순서로 상태를 재구축하지 않는다.
이 형태 계약은 서비스 검증 대상이며 Prisma Json이나 기존 SQL이 모두 강제한다는 의미는 아니다.

## Images

images는 순서 있는 JSON 배열이다. 최대 10개 객체를 저장한다.

| 키 | 값·제약 |
| --- | --- |
| storageKey | 비어 있지 않은 객체 저장 키 |
| objectVersion | 비어 있지 않은 불변 객체 버전 |
| sha256 | 소문자 hex 64자리 |
| mimeType | image/jpeg, image/png, image/webp 중 하나 |
| bytes | 1 이상, 최대 10 MiB |
| width | 1 이상, 최대 10,000 픽셀 |
| height | 1 이상, 최대 10,000 픽셀 |
| alt | 선택적 이미지 설명, SQL 필수 속성 아님 |

이미지 바이너리는 비공개 객체 저장소의 책임이며 DB에는 메타데이터만 저장한다.
서비스는 JSON 형태·메타데이터 범위를 검사한다. MySQL JSON 타입은 유효한 JSON 저장만 보장한다.
실제 바이트·MIME·픽셀·해시·업로드 권한의 확인은 저장소와 서비스의 책임이다.

## Network Evidence

소유 컬럼: [GuestIdentification.networkEvidence](../erd.md#guest_identifications). 판정 시 서버 분류 캐시를 복사한 객체이며 캐시 변경 후에도 불변이다. 적용 환경은 판정 행의 environment에 기록하고 evidence의 environment는 공급자의 원래 분류다.

| 경로 | 타입·조건 |
| --- | --- |
| provider | 캐시 공급자 문자열, 캐시 참조 시 필수 |
| providerVersion | 캐시 공급자·정책·HMAC 키 식별 문자열, 캐시 참조 시 필수 |
| connectionType | 문자열 또는 NULL, 공급자의 원래 연결 유형 |
| environment | PERSONAL / SHARED / UNKNOWN |
| isAnonymous | boolean, 캐시 참조 시 필수 |
| classifiedAt | UTC date-time 문자열, 캐시 참조 시 필수 |
| expiresAt | UTC date-time 문자열, 캐시 참조 시 필수 |
| reason | 캐시 미참조 시 NO_CLASSIFICATION |

캐시 미참조 증거는 다음 고정 형태이며 판정의 environment도 UNKNOWN이어야 한다.

```json
{
  "environment": "UNKNOWN",
  "reason": "NO_CLASSIFICATION"
}
```

클라이언트 증거를 신뢰하지 않는다. 서비스가 유효한 캐시에서 구성하고 판정 시각·캐시 만료·키 바인딩을 검증한다. 원본 IP·지문·비밀 키는 포함하지 않는다.

## Review

소유 컬럼: [Report.review](../erd.md#reports). PENDING에서는 review·reviewedAt이 NULL이다. 검수 종료 시 운영 검수자의 reviewerKey와 사유를 포함한 JSON 객체와 서버 reviewedAt을 상태·버전·이벤트와 함께 저장한다. 비회원 User를 검수자로 사용하지 않는다. 증거 payload와 별개의 검수 기록이며 검수 권한은 [신고 설계](report-moderation.md)에서 검증한다.

## Scopes

소유 컬럼: [GuestBrowserCredential.scopes](../erd.md#guest_browser_credentials). 정확히 다음 JSON 배열만 허용한다. NULL·추가 항목·중복 항목·다른 권한 문자열은 거부한다.

```json
[
  "PREFERENCES"
]
```
