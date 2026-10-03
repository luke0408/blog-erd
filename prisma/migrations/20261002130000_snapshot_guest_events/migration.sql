BEGIN;

-- CreateEnum
CREATE TYPE "SnapshotSource" AS ENUM ('USER_WRITE', 'LEGACY_IMPORT');

-- CreateEnum
CREATE TYPE "ReportEvidence" AS ENUM ('CAPTURED', 'LEGACY_UNVERIFIED');

-- DropForeignKey
ALTER TABLE "reports" DROP CONSTRAINT "reports_reporter_id_fkey";

-- DropForeignKey
ALTER TABLE "reports" DROP CONSTRAINT "reports_reviewed_by_id_fkey";

-- DropForeignKey
ALTER TABLE "reports" DROP CONSTRAINT "reports_post_id_fkey";

-- DropForeignKey
ALTER TABLE "reports" DROP CONSTRAINT "reports_comment_id_fkey";

-- DropIndex
DROP INDEX "reports_post_id_status_idx";

-- DropIndex
DROP INDEX "reports_comment_id_status_idx";

-- DropIndex
DROP INDEX "reports_reviewed_by_id_idx";

-- DropIndex
DROP INDEX "reports_reporter_id_post_id_key";

-- DropIndex
DROP INDEX "reports_reporter_id_comment_id_key";

-- AlterTable
ALTER TABLE "users" ADD COLUMN     "expires_at" TIMESTAMPTZ(3),
ADD COLUMN     "last_seen_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
ADD COLUMN     "revoked_at" TIMESTAMPTZ(3),
ADD COLUMN     "session_key" UUID,
ADD COLUMN     "token_version" INTEGER NOT NULL DEFAULT 1,
ADD COLUMN     "legacy_data" JSONB;

-- AlterTable
ALTER TABLE "posts" ADD COLUMN     "current_snapshot_id" INTEGER,
ADD COLUMN     "management_key_hash" CHAR(64),
ADD COLUMN     "version" INTEGER NOT NULL DEFAULT 1;

-- AlterTable
ALTER TABLE "comments" ADD COLUMN     "current_snapshot_id" INTEGER,
ADD COLUMN     "management_key_hash" CHAR(64),
ADD COLUMN     "version" INTEGER NOT NULL DEFAULT 1;

-- AlterTable
ALTER TABLE "reports" ADD COLUMN     "event_id" VARCHAR(128),
ADD COLUMN     "evidence" "ReportEvidence" NOT NULL DEFAULT 'CAPTURED',
ADD COLUMN     "payload" JSONB,
ADD COLUMN     "reporter_key" TEXT,
ADD COLUMN     "review" JSONB,
ADD COLUMN     "snapshot_key" TEXT,
ADD COLUMN     "target_key" TEXT,
ADD COLUMN     "version" INTEGER NOT NULL DEFAULT 1;

-- CreateTable
CREATE TABLE "post_snapshots" (
    "id" SERIAL NOT NULL,
    "post_id" INTEGER NOT NULL,
    "revision" INTEGER NOT NULL,
    "title" VARCHAR(200) NOT NULL,
    "content" TEXT NOT NULL,
    "images" JSONB NOT NULL DEFAULT '[]',
    "editor_key" TEXT,
    "source" "SnapshotSource" NOT NULL DEFAULT 'USER_WRITE',
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "post_snapshots_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "comment_snapshots" (
    "id" SERIAL NOT NULL,
    "comment_id" INTEGER NOT NULL,
    "revision" INTEGER NOT NULL,
    "content" TEXT NOT NULL,
    "editor_key" TEXT,
    "source" "SnapshotSource" NOT NULL DEFAULT 'USER_WRITE',
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "comment_snapshots_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "outbox_events" (
    "id" VARCHAR(128) NOT NULL,
    "aggregate_key" TEXT NOT NULL,
    "aggregate_version" INTEGER,
    "event_type" TEXT NOT NULL,
    "payload" JSONB NOT NULL,
    "occurred_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "available_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "attempts" INTEGER NOT NULL DEFAULT 0,
    "lease_token" UUID,
    "lease_until" TIMESTAMPTZ(3),
    "processed_at" TIMESTAMPTZ(3),
    "last_error" TEXT,

    CONSTRAINT "outbox_events_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "event_receipts" (
    "consumer" TEXT NOT NULL,
    "event_id" VARCHAR(128) NOT NULL,
    "processed_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "event_receipts_pkey" PRIMARY KEY ("consumer","event_id")
);

-- Preserve currently available content, not an invented historical revision.
UPDATE "users" SET "session_key" = gen_random_uuid(),
    "expires_at" = "created_at", "revoked_at" = CURRENT_TIMESTAMP,
    "legacy_data" = jsonb_build_object('email', "email", 'migrationSource', 'legacy-user');
ALTER TABLE "users" ALTER COLUMN "session_key" SET NOT NULL,
    ALTER COLUMN "expires_at" SET NOT NULL;
DROP INDEX "users_email_key";
ALTER TABLE "users" DROP COLUMN "email";

INSERT INTO "post_snapshots" ("post_id", "revision", "title", "content", "source")
    SELECT "id", 1, "title", "content", 'LEGACY_IMPORT' FROM "posts";
UPDATE "posts" AS p SET "current_snapshot_id" = s."id"
    FROM "post_snapshots" AS s WHERE s."post_id" = p."id";
INSERT INTO "comment_snapshots" ("comment_id", "revision", "content", "source")
    SELECT "id", 1, "content", 'LEGACY_IMPORT' FROM "comments";
UPDATE "comments" AS c SET "current_snapshot_id" = s."id"
    FROM "comment_snapshots" AS s WHERE s."comment_id" = c."id";

-- The old schema cannot prove which revision was reported. Preserve that gap.
UPDATE "reports" SET
    "event_id" = 'legacy-report:' || "id",
    "reporter_key" = 'user:' || "reporter_id",
    "target_key" = CASE WHEN "post_id" IS NOT NULL THEN 'post:' || "post_id" ELSE 'comment:' || "comment_id" END,
    "snapshot_key" = 'legacy:unknown',
    "evidence" = 'LEGACY_UNVERIFIED',
    "payload" = jsonb_build_object('schemaVersion', 0, 'evidenceUnavailable', TRUE,
        'reporterId', "reporter_id", 'postId', "post_id", 'commentId', "comment_id", 'reason', "reason"),
    "review" = CASE WHEN "reviewed_by_id" IS NULL THEN NULL
        ELSE jsonb_build_object('reviewerKey', 'legacy-user:' || "reviewed_by_id", 'legacy', TRUE) END;

ALTER TABLE "reports" DROP CONSTRAINT "reports_exactly_one_target_check",
    DROP CONSTRAINT "reports_reason_not_blank_check",
    DROP CONSTRAINT "reports_review_metadata_check";
ALTER TABLE "reports" ALTER COLUMN "event_id" SET NOT NULL,
    ALTER COLUMN "payload" SET NOT NULL, ALTER COLUMN "reporter_key" SET NOT NULL,
    ALTER COLUMN "snapshot_key" SET NOT NULL, ALTER COLUMN "target_key" SET NOT NULL,
    DROP COLUMN "comment_id", DROP COLUMN "post_id", DROP COLUMN "reason",
    DROP COLUMN "reporter_id", DROP COLUMN "reviewed_by_id";
ALTER TABLE "posts" DROP COLUMN "content", DROP COLUMN "title";
ALTER TABLE "comments" DROP COLUMN "content";

-- CreateIndex
CREATE UNIQUE INDEX "post_snapshots_post_id_revision_key" ON "post_snapshots"("post_id", "revision");

-- CreateIndex
CREATE UNIQUE INDEX "post_snapshots_post_id_id_key" ON "post_snapshots"("post_id", "id");

-- CreateIndex
CREATE UNIQUE INDEX "comment_snapshots_comment_id_revision_key" ON "comment_snapshots"("comment_id", "revision");

-- CreateIndex
CREATE UNIQUE INDEX "comment_snapshots_comment_id_id_key" ON "comment_snapshots"("comment_id", "id");

-- CreateIndex
CREATE INDEX "outbox_events_processed_at_available_at_lease_until_idx" ON "outbox_events"("processed_at", "available_at", "lease_until");

-- CreateIndex
CREATE UNIQUE INDEX "outbox_events_aggregate_key_aggregate_version_key" ON "outbox_events"("aggregate_key", "aggregate_version");

-- CreateIndex
CREATE UNIQUE INDEX "users_session_key_key" ON "users"("session_key");

-- CreateIndex
CREATE UNIQUE INDEX "posts_id_current_snapshot_id_key" ON "posts"("id", "current_snapshot_id");

-- CreateIndex
CREATE UNIQUE INDEX "comments_id_current_snapshot_id_key" ON "comments"("id", "current_snapshot_id");

-- CreateIndex
CREATE UNIQUE INDEX "reports_event_id_key" ON "reports"("event_id");

-- CreateIndex
CREATE INDEX "reports_target_key_status_evidence_idx" ON "reports"("target_key", "status", "evidence");

-- CreateIndex
CREATE UNIQUE INDEX "reports_reporter_key_target_key_snapshot_key_key" ON "reports"("reporter_key", "target_key", "snapshot_key");

-- AddForeignKey
ALTER TABLE "posts" ADD CONSTRAINT "posts_id_current_snapshot_id_fkey" FOREIGN KEY ("id", "current_snapshot_id") REFERENCES "post_snapshots"("post_id", "id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "post_snapshots" ADD CONSTRAINT "post_snapshots_post_id_fkey" FOREIGN KEY ("post_id") REFERENCES "posts"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "comments" ADD CONSTRAINT "comments_id_current_snapshot_id_fkey" FOREIGN KEY ("id", "current_snapshot_id") REFERENCES "comment_snapshots"("comment_id", "id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "comment_snapshots" ADD CONSTRAINT "comment_snapshots_comment_id_fkey" FOREIGN KEY ("comment_id") REFERENCES "comments"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

CREATE FUNCTION "valid_snapshot_images"(items JSONB) RETURNS BOOLEAN LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(items) <> 'array' THEN FALSE ELSE
        jsonb_array_length(items) <= 10 AND NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(items) AS image
            WHERE NOT COALESCE(
                jsonb_typeof(image) = 'object'
                AND jsonb_typeof(image->'storageKey') = 'string' AND LENGTH(image->>'storageKey') > 0
                AND jsonb_typeof(image->'objectVersion') = 'string' AND LENGTH(image->>'objectVersion') > 0
                AND image->>'sha256' ~ '^[0-9a-f]{64}$'
                AND image->>'mimeType' IN ('image/jpeg', 'image/png', 'image/webp')
                AND jsonb_typeof(image->'bytes') = 'number' AND (image->>'bytes')::NUMERIC BETWEEN 1 AND 10485760
                AND jsonb_typeof(image->'width') = 'number' AND (image->>'width')::NUMERIC BETWEEN 1 AND 10000
                AND jsonb_typeof(image->'height') = 'number' AND (image->>'height')::NUMERIC BETWEEN 1 AND 10000,
                FALSE)
        ) END;
$$;
ALTER TABLE "post_snapshots" ADD CONSTRAINT "post_snapshot_shape_check"
    CHECK ("revision" > 0 AND valid_snapshot_images("images")
        AND ("source" = 'LEGACY_IMPORT' OR ("editor_key" IS NOT NULL AND LENGTH("editor_key") > 0)));
ALTER TABLE "comment_snapshots" ADD CONSTRAINT "comment_snapshot_shape_check"
    CHECK ("revision" > 0
        AND ("source" = 'LEGACY_IMPORT' OR ("editor_key" IS NOT NULL AND LENGTH("editor_key") > 0)));
ALTER TABLE "posts" ADD CONSTRAINT "post_version_key_check"
    CHECK ("version" > 0 AND ("management_key_hash" IS NULL OR "management_key_hash" ~ '^[0-9a-f]{64}$'));
ALTER TABLE "comments" ADD CONSTRAINT "comment_version_key_check"
    CHECK ("version" > 0 AND ("management_key_hash" IS NULL OR "management_key_hash" ~ '^[0-9a-f]{64}$'));
ALTER TABLE "users" ADD CONSTRAINT "guest_session_version_check" CHECK ("token_version" > 0);
ALTER TABLE "reports" ADD CONSTRAINT "report_payload_check" CHECK (COALESCE(
    jsonb_typeof("payload") = 'object' AND "version" > 0 AND (
        ("evidence" = 'LEGACY_UNVERIFIED' AND "payload"->>'schemaVersion' = '0'
            AND "payload"->>'evidenceUnavailable' = 'true' AND "snapshot_key" = 'legacy:unknown')
        OR
        ("evidence" = 'CAPTURED' AND "payload"->>'schemaVersion' = '1'
            AND "payload"->'target'->>'kind' IN ('POST', 'COMMENT')
            AND jsonb_typeof("payload"->'actor'->'userId') = 'number'
            AND jsonb_typeof("payload"->'target'->'resourceId') = 'number'
            AND jsonb_typeof("payload"->'target'->'snapshotId') = 'number'
            AND jsonb_typeof("payload"->'target'->'revision') = 'number'
            AND jsonb_typeof("payload"->'snapshot') = 'object'
            AND jsonb_typeof("payload"->'snapshot'->'content') = 'string'
            AND jsonb_typeof("payload"->'snapshot'->'created_at') = 'string'
            AND "payload"->'snapshot'->>'source' IN ('USER_WRITE', 'LEGACY_IMPORT')
            AND ("payload"->'target'->>'resourceId')::NUMERIC > 0
            AND ("payload"->'target'->>'snapshotId')::NUMERIC > 0
            AND ("payload"->'target'->>'revision')::NUMERIC > 0
            AND "payload"->'snapshot'->>'id' = "payload"->'target'->>'snapshotId'
            AND "payload"->'snapshot'->>'revision' = "payload"->'target'->>'revision'
            AND CASE WHEN "payload"->'target'->>'kind' = 'POST' THEN
                "payload"->'snapshot'->>'post_id' = "payload"->'target'->>'resourceId'
                AND jsonb_typeof("payload"->'snapshot'->'title') = 'string'
                AND COALESCE(valid_snapshot_images("payload"->'snapshot'->'images'), FALSE)
                ELSE "payload"->'snapshot'->>'comment_id' = "payload"->'target'->>'resourceId' END
            AND jsonb_typeof("payload"->'reason'->'detail') = 'string'
            AND LENGTH(BTRIM("payload"->'reason'->>'detail')) BETWEEN 1 AND 500
            AND "reporter_key" = 'user:' || ("payload"->'actor'->>'userId')
            AND "target_key" = LOWER("payload"->'target'->>'kind') || ':' || ("payload"->'target'->>'resourceId')
            AND "snapshot_key" = LOWER("payload"->'target'->>'kind') || '-snapshot:' || ("payload"->'target'->>'snapshotId'))
    ), FALSE));
ALTER TABLE "reports" ADD CONSTRAINT "report_review_check" CHECK (COALESCE(
    ("status" = 'PENDING' AND "review" IS NULL AND "reviewed_at" IS NULL)
    OR ("status" <> 'PENDING' AND jsonb_typeof("review") = 'object'
        AND LENGTH("review"->>'reviewerKey') > 0 AND "reviewed_at" IS NOT NULL), FALSE));
ALTER TABLE "outbox_events" ADD CONSTRAINT "outbox_shape_check"
    CHECK (jsonb_typeof("payload") = 'object' AND "attempts" >= 0
        AND ("aggregate_version" IS NULL OR "aggregate_version" > 0)
        AND (("lease_token" IS NULL) = ("lease_until" IS NULL)));

CREATE FUNCTION "reject_history_mutation"() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END;
$$;
CREATE FUNCTION "require_user_snapshot"() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.source <> 'USER_WRITE' THEN
        RAISE EXCEPTION 'legacy imports are reserved for the migration';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER "post_snapshot_source" BEFORE INSERT ON "post_snapshots"
    FOR EACH ROW EXECUTE FUNCTION "require_user_snapshot"();
CREATE TRIGGER "comment_snapshot_source" BEFORE INSERT ON "comment_snapshots"
    FOR EACH ROW EXECUTE FUNCTION "require_user_snapshot"();
CREATE TRIGGER "immutable_post_snapshot" BEFORE UPDATE OR DELETE ON "post_snapshots"
    FOR EACH ROW EXECUTE FUNCTION "reject_history_mutation"();
CREATE TRIGGER "immutable_comment_snapshot" BEFORE UPDATE OR DELETE ON "comment_snapshots"
    FOR EACH ROW EXECUTE FUNCTION "reject_history_mutation"();
CREATE TRIGGER "immutable_event_receipt" BEFORE UPDATE OR DELETE ON "event_receipts"
    FOR EACH ROW EXECUTE FUNCTION "reject_history_mutation"();
CREATE TRIGGER "retain_report" BEFORE DELETE ON "reports"
    FOR EACH ROW EXECUTE FUNCTION "reject_history_mutation"();
CREATE TRIGGER "retain_event" BEFORE DELETE ON "outbox_events"
    FOR EACH ROW EXECUTE FUNCTION "reject_history_mutation"();

CREATE FUNCTION "protect_event_evidence"() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'reports' THEN
        IF ROW(NEW.id, NEW.event_id, NEW.reporter_key, NEW.target_key, NEW.snapshot_key, NEW.payload, NEW.evidence, NEW.created_at)
            IS DISTINCT FROM ROW(OLD.id, OLD.event_id, OLD.reporter_key, OLD.target_key, OLD.snapshot_key, OLD.payload, OLD.evidence, OLD.created_at)
            OR NEW.version <> OLD.version + 1 OR OLD.status <> 'PENDING' THEN
            RAISE EXCEPTION 'report evidence is immutable; review requires a new version';
        END IF;
    ELSE
        IF ROW(NEW.id, NEW.aggregate_key, NEW.aggregate_version, NEW.event_type, NEW.payload, NEW.occurred_at)
            IS DISTINCT FROM ROW(OLD.id, OLD.aggregate_key, OLD.aggregate_version, OLD.event_type, OLD.payload, OLD.occurred_at) THEN
            RAISE EXCEPTION 'event envelope is immutable';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER "immutable_report_evidence" BEFORE UPDATE ON "reports"
    FOR EACH ROW EXECUTE FUNCTION "protect_event_evidence"();
CREATE TRIGGER "immutable_event_envelope" BEFORE UPDATE ON "outbox_events"
    FOR EACH ROW EXECUTE FUNCTION "protect_event_evidence"();

CREATE FUNCTION "protect_content_metadata"() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.id, NEW.author_id, NEW.created_at, NEW.management_key_hash)
        IS DISTINCT FROM ROW(OLD.id, OLD.author_id, OLD.created_at, OLD.management_key_hash)
        OR OLD.status = 'DELETED' THEN
        RAISE EXCEPTION 'content ownership/key/deleted state is immutable';
    END IF;
    IF TG_TABLE_NAME = 'comments' AND
        (to_jsonb(NEW)->'post_id' IS DISTINCT FROM to_jsonb(OLD)->'post_id'
        OR to_jsonb(NEW)->'parent_id' IS DISTINCT FROM to_jsonb(OLD)->'parent_id') THEN
        RAISE EXCEPTION 'comment placement is immutable';
    END IF;
    IF NOT (OLD.current_snapshot_id IS NULL AND NEW.current_snapshot_id IS NOT NULL AND NEW.version = OLD.version)
        AND NEW.version <> OLD.version + 1 THEN
        RAISE EXCEPTION 'content version must advance by one';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER "protect_post_metadata" BEFORE UPDATE ON "posts"
    FOR EACH ROW EXECUTE FUNCTION "protect_content_metadata"();
CREATE TRIGGER "protect_comment_metadata" BEFORE UPDATE ON "comments"
    FOR EACH ROW EXECUTE FUNCTION "protect_content_metadata"();

-- Nullable pointers support insert-root/insert-snapshot/update-root in one transaction.
-- At commit the pointer must reference the owner's highest existing revision.
CREATE FUNCTION "require_latest_snapshot"() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    root_id INTEGER;
    valid BOOLEAN;
BEGIN
    IF TG_TABLE_NAME IN ('posts', 'post_snapshots') THEN
        root_id := (to_jsonb(NEW)->>(CASE WHEN TG_TABLE_NAME = 'posts' THEN 'id' ELSE 'post_id' END))::INTEGER;
        PERFORM 1 FROM posts WHERE id = root_id FOR UPDATE;
        SELECT s.revision = (SELECT MAX(h.revision) FROM post_snapshots h WHERE h.post_id = p.id)
            AND (s.source = 'LEGACY_IMPORT' OR p.management_key_hash IS NOT NULL)
            INTO valid FROM posts p LEFT JOIN post_snapshots s ON s.id = p.current_snapshot_id AND s.post_id = p.id
            WHERE p.id = root_id;
    ELSE
        root_id := (to_jsonb(NEW)->>(CASE WHEN TG_TABLE_NAME = 'comments' THEN 'id' ELSE 'comment_id' END))::INTEGER;
        PERFORM 1 FROM comments WHERE id = root_id FOR UPDATE;
        SELECT s.revision = (SELECT MAX(h.revision) FROM comment_snapshots h WHERE h.comment_id = c.id)
            AND (s.source = 'LEGACY_IMPORT' OR c.management_key_hash IS NOT NULL)
            INTO valid FROM comments c LEFT JOIN comment_snapshots s ON s.id = c.current_snapshot_id AND s.comment_id = c.id
            WHERE c.id = root_id;
    END IF;
    IF valid IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'content requires its latest snapshot and a management key for new writes';
    END IF;
    RETURN NULL;
END;
$$;
CREATE CONSTRAINT TRIGGER "post_latest_snapshot" AFTER INSERT OR UPDATE ON "posts"
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "require_latest_snapshot"();
CREATE CONSTRAINT TRIGGER "post_history_latest_snapshot" AFTER INSERT ON "post_snapshots"
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "require_latest_snapshot"();
CREATE CONSTRAINT TRIGGER "comment_latest_snapshot" AFTER INSERT OR UPDATE ON "comments"
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "require_latest_snapshot"();
CREATE CONSTRAINT TRIGGER "comment_history_latest_snapshot" AFTER INSERT ON "comment_snapshots"
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "require_latest_snapshot"();

COMMIT;
