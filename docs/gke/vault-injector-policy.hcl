# The injected Agent only needs runtime application and storage credentials.
# The migration and database password remain in separately managed Kubernetes
# Secrets because of current chart constraints.
path "kv/data/apps/lightdash/application" {
  capabilities = ["read"]
}

path "kv/data/apps/lightdash/s3" {
  capabilities = ["read"]
}
