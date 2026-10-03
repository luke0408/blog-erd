BEGIN;

-- CreateEnum
CREATE TYPE "GuestEnvironment" AS ENUM ('PERSONAL', 'SHARED', 'UNKNOWN');

-- CreateEnum
CREATE TYPE "GuestResolutionMethod" AS ENUM ('SESSION_TOKEN', 'NEW_SESSION', 'RECOVERY_CREDENTIAL');

-- AlterTable
ALTER TABLE "users" ADD COLUMN     "browser_credential_id" UUID;

-- CreateTable
CREATE TABLE "guest_browser_credentials" (
    "id" UUID NOT NULL,
    "secret_hash" CHAR(64) NOT NULL,
    "version" INTEGER NOT NULL DEFAULT 1,
    "scopes" TEXT[] DEFAULT ARRAY['PREFERENCES']::TEXT[],
    "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "last_used_at" TIMESTAMPTZ(3),
    "expires_at" TIMESTAMPTZ(3) NOT NULL,
    "revoked_at" TIMESTAMPTZ(3),

    CONSTRAINT "guest_browser_credentials_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "network_classifications" (
    "id" SERIAL NOT NULL,
    "ip_digest" CHAR(64) NOT NULL,
    "provider" VARCHAR(32) NOT NULL,
    "provider_version" VARCHAR(64) NOT NULL,
    "connection_type" VARCHAR(64),
    "environment" "GuestEnvironment" NOT NULL DEFAULT 'UNKNOWN',
    "is_anonymous" BOOLEAN NOT NULL DEFAULT false,
    "classified_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expires_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "network_classifications_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "guest_identifications" (
    "id" SERIAL NOT NULL,
    "user_id" INTEGER NOT NULL,
    "browser_credential_id" UUID,
    "network_classification_id" INTEGER,
    "environment" "GuestEnvironment" NOT NULL DEFAULT 'UNKNOWN',
    "method" "GuestResolutionMethod" NOT NULL DEFAULT 'NEW_SESSION',
    "reason_code" VARCHAR(64) NOT NULL,
    "fingerprint_digest" CHAR(64),
    "private_ip_digest" CHAR(64),
    "idle_seconds" INTEGER,
    "client_timestamp" TIMESTAMPTZ(3),
    "network_evidence" JSONB NOT NULL DEFAULT '{}',
    "received_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expires_at" TIMESTAMPTZ(3) NOT NULL,

    CONSTRAINT "guest_identifications_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "guest_browser_credentials_secret_hash_key" ON "guest_browser_credentials"("secret_hash");

-- CreateIndex
CREATE INDEX "network_classifications_expires_at_idx" ON "network_classifications"("expires_at");

-- CreateIndex
CREATE UNIQUE INDEX "network_classifications_ip_digest_provider_key" ON "network_classifications"("ip_digest", "provider");

-- CreateIndex
CREATE INDEX "guest_identifications_user_id_received_at_idx" ON "guest_identifications"("user_id", "received_at");

-- CreateIndex
CREATE INDEX "guest_identifications_fingerprint_digest_received_at_idx" ON "guest_identifications"("fingerprint_digest", "received_at");

-- CreateIndex
CREATE INDEX "guest_identifications_expires_at_idx" ON "guest_identifications"("expires_at");

-- AddForeignKey
ALTER TABLE "users" ADD CONSTRAINT "users_browser_credential_id_fkey" FOREIGN KEY ("browser_credential_id") REFERENCES "guest_browser_credentials"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "guest_identifications" ADD CONSTRAINT "guest_identifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "guest_identifications" ADD CONSTRAINT "guest_identifications_browser_credential_id_fkey" FOREIGN KEY ("browser_credential_id") REFERENCES "guest_browser_credentials"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

-- AddForeignKey
ALTER TABLE "guest_identifications" ADD CONSTRAINT "guest_identifications_network_classification_id_fkey" FOREIGN KEY ("network_classification_id") REFERENCES "network_classifications"("id") ON DELETE RESTRICT ON UPDATE NO ACTION;

ALTER TABLE guest_browser_credentials
    ALTER COLUMN scopes SET NOT NULL,
    ADD CONSTRAINT guest_browser_credential_shape_check CHECK (
        secret_hash ~ '^[0-9a-f]{64}$' AND version > 0
        AND scopes = ARRAY['PREFERENCES']::text[]
        AND expires_at > created_at
    );

ALTER TABLE network_classifications
    ADD CONSTRAINT network_classification_shape_check CHECK (
        ip_digest ~ '^[0-9a-f]{64}$'
        AND length(trim(provider)) > 0 AND length(trim(provider_version)) > 0
        AND expires_at > classified_at
        AND expires_at <= classified_at + INTERVAL '1 hour'
        AND (NOT is_anonymous OR environment <> 'PERSONAL')
    );

ALTER TABLE guest_identifications
    ADD CONSTRAINT guest_identification_shape_check CHECK (
        length(trim(reason_code)) > 0
        AND jsonb_typeof(network_evidence) = 'object'
        AND (fingerprint_digest IS NULL OR fingerprint_digest ~ '^[0-9a-f]{64}$')
        AND (private_ip_digest IS NULL OR private_ip_digest ~ '^[0-9a-f]{64}$')
        AND (idle_seconds IS NULL OR idle_seconds >= 0)
        AND expires_at > received_at
        AND expires_at <= received_at + INTERVAL '7 days'
        AND (environment = 'PERSONAL' OR browser_credential_id IS NULL)
        AND (method <> 'RECOVERY_CREDENTIAL' OR (
            environment = 'PERSONAL'
            AND browser_credential_id IS NOT NULL
            AND network_classification_id IS NOT NULL
        ))
    );

CREATE FUNCTION protect_guest_session_binding() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.id, NEW.session_key, NEW.created_at, NEW.browser_credential_id)
        IS DISTINCT FROM ROW(OLD.id, OLD.session_key, OLD.created_at, OLD.browser_credential_id) THEN
        RAISE EXCEPTION 'guest session binding is immutable; create a new visit';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER protect_guest_session_binding BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION protect_guest_session_binding();

CREATE FUNCTION protect_browser_credential() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.id, NEW.secret_hash, NEW.scopes, NEW.created_at, NEW.expires_at)
        IS DISTINCT FROM ROW(OLD.id, OLD.secret_hash, OLD.scopes, OLD.created_at, OLD.expires_at)
        OR NEW.version < OLD.version
        OR (OLD.revoked_at IS NOT NULL AND NEW.revoked_at IS DISTINCT FROM OLD.revoked_at) THEN
        RAISE EXCEPTION 'browser credential scope and lifetime are immutable; issue a new credential';
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER protect_browser_credential BEFORE UPDATE ON guest_browser_credentials
    FOR EACH ROW EXECUTE FUNCTION protect_browser_credential();

-- Capture server-side cache evidence; this does not verify a presented bearer secret.
CREATE FUNCTION guard_guest_identification() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    network network_classifications%ROWTYPE;
    credential guest_browser_credentials%ROWTYPE;
    bound_credential uuid;
BEGIN
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'guest identification decisions are immutable';
    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.expires_at > CURRENT_TIMESTAMP THEN
            RAISE EXCEPTION 'guest identification retention has not expired';
        END IF;
        RETURN OLD;
    END IF;

    NEW.received_at := CURRENT_TIMESTAMP;
    IF NEW.network_classification_id IS NULL THEN
        IF NEW.environment <> 'UNKNOWN' THEN
            RAISE EXCEPTION 'network classification is required for a known environment';
        END IF;
        NEW.network_evidence := '{"environment":"UNKNOWN","reason":"NO_CLASSIFICATION"}'::jsonb;
    ELSE
        SELECT * INTO network FROM network_classifications
            WHERE id = NEW.network_classification_id FOR SHARE;
        IF NOT FOUND OR network.expires_at <= CURRENT_TIMESTAMP
            OR network.classified_at > CURRENT_TIMESTAMP THEN
            RAISE EXCEPTION 'network classification is missing or expired';
        END IF;
        -- A client/shared-mode signal may downgrade PERSONAL, never upgrade SHARED/UNKNOWN.
        IF NEW.environment = 'PERSONAL' AND network.environment <> 'PERSONAL' THEN
            RAISE EXCEPTION 'network classification cannot be upgraded to PERSONAL';
        END IF;
        NEW.network_evidence := jsonb_build_object(
            'provider', network.provider, 'providerVersion', network.provider_version,
            'connectionType', network.connection_type, 'environment', network.environment,
            'isAnonymous', network.is_anonymous, 'classifiedAt', network.classified_at,
            'expiresAt', network.expires_at
        );
    END IF;

    SELECT browser_credential_id INTO bound_credential FROM users WHERE id = NEW.user_id FOR SHARE;
    IF NEW.browser_credential_id IS DISTINCT FROM bound_credential THEN
        RAISE EXCEPTION 'guest identification must match the session credential binding';
    END IF;
    IF NEW.browser_credential_id IS NOT NULL THEN
        SELECT * INTO credential FROM guest_browser_credentials
            WHERE id = NEW.browser_credential_id FOR SHARE;
        IF NOT FOUND OR credential.revoked_at IS NOT NULL
            OR credential.expires_at <= CURRENT_TIMESTAMP
            OR credential.created_at > CURRENT_TIMESTAMP THEN
            RAISE EXCEPTION 'browser credential is missing, expired or revoked';
        END IF;
        IF NEW.environment <> 'PERSONAL' OR NEW.network_classification_id IS NULL THEN
            RAISE EXCEPTION 'browser recovery requires a fresh PERSONAL classification';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER guard_guest_identification BEFORE INSERT OR UPDATE OR DELETE ON guest_identifications
    FOR EACH ROW EXECUTE FUNCTION guard_guest_identification();

COMMIT;
