-- =============================================================================
-- 01_storage_volume.sql
-- Create and configure the S3 storage volume for StarRocks shared-data mode.
--
-- Run once during initial cluster setup (idempotent via IF NOT EXISTS).
-- Target: any FE node via MySQL client (port 9030)
--
-- Why this is the first step:
--   In shared-data mode, all persistent data lives in S3. Tables that reference
--   this storage volume cannot be created until the volume exists. This DDL
--   must succeed before any table DDL is run.
--
-- Credentials:
--   S3 access key and secret are injected by Vault Agent Sidecar into fe.conf
--   before the FE container starts. If the StarRocks version reads credentials
--   from the volume PROPERTIES directly (rather than fe.conf), uncomment the
--   credential properties below and populate them from the Vault-injected values.
--   See starrocks-architecture.md Section 7.3.
--
-- TBD values (resolve before deploy):
--   - S3 endpoint URL   (MinIO service URL or NetApp endpoint)
--   - S3 bucket name    (must be pre-created before this DDL runs)
--   - aws.s3.region     (use 'us-east-1' for MinIO compatibility unless configured otherwise)
-- =============================================================================

-- Create the shared-data storage volume.
-- IF NOT EXISTS makes this idempotent — safe to re-run after cluster rebuild.
CREATE STORAGE VOLUME IF NOT EXISTS s3_volume
TYPE = S3
LOCATIONS = ("s3://your-bucket/starrocks")  -- TBD: replace with actual bucket name and path prefix
PROPERTIES (
    "enabled" = "true",

    -- TBD: set to the region configured in MinIO or NetApp.
    -- MinIO typically requires "us-east-1" regardless of deployment region
    -- unless the endpoint is configured with a custom region.
    "aws.s3.region" = "us-east-1",

    -- TBD: replace with the actual S3-compatible endpoint.
    -- MinIO example: "http://minio-service.minio.svc.cluster.local:9000"
    -- NetApp example: "https://s3.netapp-endpoint.example.com"
    "aws.s3.endpoint" = "http://minio-service:9000"

    -- Credentials: uncomment if StarRocks reads them from volume PROPERTIES.
    -- If credentials are supplied via fe.conf (Vault Agent Sidecar injection),
    -- leave these commented out — FE reads them from config at startup.
    -- "aws.s3.access_key" = "<injected by Vault Agent>",
    -- "aws.s3.secret_key" = "<injected by Vault Agent>"
);

-- Set this volume as the cluster-wide default.
-- All tables created without an explicit 'storage_volume' property will use it.
SET DEFAULT STORAGE VOLUME s3_volume;

-- Verify:
-- SHOW STORAGE VOLUMES;
-- DESC STORAGE VOLUME s3_volume;
