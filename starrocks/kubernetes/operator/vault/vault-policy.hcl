# Vault policy for StarRocks FE, CN, and init Job pods
#
# Architecture reference: starrocks/kubernetes/starrocks-architecture.md §7.3
#
# Grants read access to the secrets that the Vault Agent init container renders
# into the pod filesystem at startup, and that the init Job uses to create the
# S3 storage volume.
#
# Apply with:
#   vault policy write starrocks vault/vault-policy.hcl
#
# Then create (or update) the Kubernetes auth role:
#   vault write auth/kubernetes/role/starrocks \
#     bound_service_account_names=starrocks \
#     bound_service_account_namespaces=starrocks \
#     policies=starrocks \
#     ttl=1h
#
# TBD (Open Decision #1): Adjust the KV path to match your Vault mount and secret
# namespace. If using KV v1 (not KV v2), remove the "/data/" segment:
#   KV v2: secret/data/starrocks/s3/credentials
#   KV v1: secret/starrocks/s3/credentials

# ─── S3 storage credentials ───────────────────────────────────────────────────
# Required by:
#   - The init Job to create the S3 storage volume (CREATE STORAGE VOLUME DDL)
#   - FE and CN pods for the Vault Agent sidecar (writes drop-in conf fragment)
#
# Expected secret fields:
#   access_key_id     — S3 access key
#   secret_access_key — S3 secret key
path "secret/data/starrocks/s3/credentials" {
  capabilities = ["read"]
}

# ─── StarRocks user passwords ─────────────────────────────────────────────────
# Uncomment to manage StarRocks user passwords via Vault.
# The rendered conf would be applied via ALTER USER DDL in the init Job.
#
# path "secret/data/starrocks/users/*" {
#   capabilities = ["read"]
# }
