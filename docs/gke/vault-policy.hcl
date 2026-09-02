# KV v2 data API paths contain /data/ even though `vault kv` CLI paths do not.
path "kv/data/apps/lightdash/application" {
  capabilities = ["read"]
}

path "kv/data/apps/lightdash/database" {
  capabilities = ["read"]
}

path "kv/data/apps/lightdash/s3" {
  capabilities = ["read"]
}
