BEGIN;

CREATE TYPE "ReportTargetType" AS ENUM ('POST', 'COMMENT');
ALTER TABLE reports ADD COLUMN target_type "ReportTargetType",
    ADD COLUMN target_id INTEGER,
    ADD COLUMN target_author_key VARCHAR(128);

-- Backfill projections only; never rewrite historical evidence or review versions.
-- Invalid/non-integer legacy keys fail the migration rather than inventing a target.
ALTER TABLE reports DISABLE TRIGGER immutable_report_evidence;
UPDATE reports SET
    target_type = CASE split_part(target_key, ':', 1)
        WHEN 'post' THEN 'POST'::"ReportTargetType"
        WHEN 'comment' THEN 'COMMENT'::"ReportTargetType" END,
    target_id = split_part(target_key, ':', 2)::integer;
ALTER TABLE reports ENABLE TRIGGER immutable_report_evidence;
ALTER TABLE reports ALTER COLUMN target_type SET NOT NULL, ALTER COLUMN target_id SET NOT NULL;

ALTER TABLE reports DROP CONSTRAINT report_payload_check;
-- Preserve the v0/v1 reading contract, and permit v2 with the same base evidence checks.
ALTER TABLE reports ADD CONSTRAINT report_payload_check CHECK (COALESCE(
    jsonb_typeof(payload) = 'object' AND version > 0 AND (
        (evidence = 'LEGACY_UNVERIFIED' AND payload->>'schemaVersion' = '0'
            AND payload->>'evidenceUnavailable' = 'true' AND snapshot_key = 'legacy:unknown')
        OR
        (evidence = 'CAPTURED' AND payload->>'schemaVersion' IN ('1', '2')
            AND payload->'target'->>'kind' IN ('POST', 'COMMENT')
            AND jsonb_typeof(payload->'actor'->'userId') = 'number'
            AND jsonb_typeof(payload->'target'->'resourceId') = 'number'
            AND jsonb_typeof(payload->'target'->'snapshotId') = 'number'
            AND jsonb_typeof(payload->'target'->'revision') = 'number'
            AND jsonb_typeof(payload->'snapshot') = 'object'
            AND jsonb_typeof(payload->'snapshot'->'content') = 'string'
            AND jsonb_typeof(payload->'snapshot'->'created_at') = 'string'
            AND payload->'snapshot'->>'source' IN ('USER_WRITE', 'LEGACY_IMPORT')
            AND (payload->'target'->>'resourceId')::numeric > 0
            AND (payload->'target'->>'snapshotId')::numeric > 0
            AND (payload->'target'->>'revision')::numeric > 0
            AND payload->'snapshot'->>'id' = payload->'target'->>'snapshotId'
            AND payload->'snapshot'->>'revision' = payload->'target'->>'revision'
            AND CASE WHEN payload->'target'->>'kind' = 'POST' THEN
                payload->'snapshot'->>'post_id' = payload->'target'->>'resourceId'
                AND jsonb_typeof(payload->'snapshot'->'title') = 'string'
                AND COALESCE(valid_snapshot_images(payload->'snapshot'->'images'), false)
                ELSE payload->'snapshot'->>'comment_id' = payload->'target'->>'resourceId' END
            AND jsonb_typeof(payload->'reason'->'detail') = 'string'
            AND length(btrim(payload->'reason'->>'detail')) BETWEEN 1 AND 500
            AND reporter_key = 'user:' || (payload->'actor'->>'userId')
            AND target_key = lower(payload->'target'->>'kind') || ':' || (payload->'target'->>'resourceId')
            AND snapshot_key = lower(payload->'target'->>'kind') || '-snapshot:' || (payload->'target'->>'snapshotId'))
    ), false));

ALTER TABLE reports ADD CONSTRAINT report_target_projection_check CHECK (COALESCE(
    target_id > 0
    AND target_key = lower(target_type::text) || ':' || target_id::text
    AND (
        (evidence = 'LEGACY_UNVERIFIED' AND target_author_key IS NULL)
        OR (evidence = 'CAPTURED'
            AND payload->'target'->>'kind' = target_type::text
            AND payload->'target'->>'resourceId' = target_id::text
            AND (
                (payload->>'schemaVersion' = '1' AND target_author_key IS NULL)
                OR (payload->>'schemaVersion' = '2'
                    AND jsonb_typeof(payload->'schemaVersion') = 'number'
                    AND target_author_key IS NOT NULL AND target_author_key ~ '^user:[1-9][0-9]*$'
                    AND jsonb_typeof(payload->'target'->'authorKey') = 'string'
                    AND target_author_key = payload->'target'->>'authorKey'
                    AND payload->'actor'->>'userId' ~ '^[1-9][0-9]*$'
                    AND payload->'target'->>'snapshotId' ~ '^[1-9][0-9]*$'
                    AND payload->'target'->>'revision' ~ '^[1-9][0-9]*$'
                    AND jsonb_typeof(payload->'snapshot'->'editor_key') IN ('string', 'null')
                    AND (payload->'snapshot'->>'source' <> 'USER_WRITE'
                        OR payload->'snapshot'->>'editor_key' ~ '^user:[1-9][0-9]*$')
                    AND CASE WHEN target_type = 'POST' THEN
                        NOT (payload->'snapshot' ? 'comment_id')
                        ELSE NOT (payload->'snapshot' ?| ARRAY['post_id', 'title', 'images']) END
                )
            )
        )
    ), false));

CREATE INDEX reports_target_type_target_id_status_evidence_idx ON reports(target_type, target_id, status, evidence);
CREATE INDEX reports_status_created_at_id_idx ON reports(status, created_at, id);
CREATE INDEX reports_target_author_key_created_at_idx ON reports(target_author_key, created_at);

CREATE FUNCTION guard_report_target() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.evidence <> 'CAPTURED' OR NEW.payload->>'schemaVersion' IS DISTINCT FROM '2' THEN
            RAISE EXCEPTION 'new reports require captured v2 evidence; legacy versions are read-only';
        END IF;
    ELSIF ROW(NEW.target_type, NEW.target_id, NEW.target_author_key)
        IS DISTINCT FROM ROW(OLD.target_type, OLD.target_id, OLD.target_author_key) THEN
        RAISE EXCEPTION 'report target projections are immutable';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER guard_report_target BEFORE INSERT OR UPDATE ON reports
    FOR EACH ROW EXECUTE FUNCTION guard_report_target();

COMMIT;
