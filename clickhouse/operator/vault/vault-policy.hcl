# Vault policy for ClickHouse cache pods
#
# Architecture reference: docs/architecture.md §7.4
#
# Grants read access to the secrets that the Vault Agent init container
# renders into ClickHouse config.d/ XML files at pod startup.
#
# Apply with:
#   vault policy write clickhouse-cache vault/vault-policy.hcl
#
# Then create (or update) the Kubernetes auth role:
#   vault write auth/kubernetes/role/clickhouse-cache \
#     bound_service_account_names=clickhouse \
#     bound_service_account_namespaces=clickhouse \
#     policies=clickhouse-cache \
#     ttl=1h
#
# TBD (Q1): Adjust the KV path to match your Vault mount and secret namespace.
# If using KV v1 (not KV v2), remove the "/data/" segment from the path:
#   KV v2: secret/data/clickhouse/s3/credentials
#   KV v1: secret/clickhouse/s3/credentials

# ─── S3 storage credentials ───────────────────────────────────────────────────
# Required by all cache pods for write-through INSERT and read-through cache miss.
# The rendered XML is injected into /etc/clickhouse-server/config.d/s3-credentials.xml.
# Provides <access_key_id> and <secret_access_key> for the s3_main disk.
path "secret/data/clickhouse/s3/credentials" {
  capabilities = ["read"]
}

# ─── ClickHouse user passwords ────────────────────────────────────────────────
# Uncomment if ClickHouse user passwords are managed in Vault (recommended).
# The rendered XML would be injected into /etc/clickhouse-server/users.d/users.xml.
#
# path "secret/data/clickhouse/users/*" {
#   capabilities = ["read"]
# }

# ─── Interserver secret ───────────────────────────────────────────────────────
# The Altinity operator auto-sets interserver_secret for pods in the same CHI,
# so this is not required unless you manage interserver auth separately.
#
# path "secret/data/clickhouse/interserver" {
#   capabilities = ["read"]
# }

# ─── Kafka SASL credentials (ingest pods) ────────────────────────────────────
# Uncomment if Kafka requires SASL authentication and credentials are stored in Vault.
# Configure a separate "clickhouse-ingest" policy and role for ingest pods.
#
# path "secret/data/clickhouse/kafka/credentials" {
#   capabilities = ["read"]
# }
