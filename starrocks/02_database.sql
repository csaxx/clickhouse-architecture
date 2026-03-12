-- =============================================================================
-- 02_database.sql
-- Create the application database.
--
-- Run after: 01_storage_volume.sql
-- Target: any FE node via MySQL client (port 9030)
--
-- StarRocks databases do not require a storage engine declaration.
-- All engine and storage settings are specified at the table level.
--
-- The database definition is cluster-global: FE metadata (BDB-JE) synchronizes
-- it to all FE nodes automatically. No 'ON CLUSTER' equivalent is needed.
--
-- In ClickHouse this database was created with ENGINE = Replicated(...) on both
-- the cache cluster and the ingest cluster. In StarRocks there is one unified
-- database — no separate ingest vs. cache database distinction exists.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS events_db
COMMENT "Event analytics database";

-- Verify:
-- SHOW DATABASES;
-- SHOW CREATE DATABASE events_db;
