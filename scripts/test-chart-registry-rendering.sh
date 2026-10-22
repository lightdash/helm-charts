#!/usr/bin/env bash

# Renders the chart with and without the chartRegistry values and checks the
# resulting ConfigMap and workload env wiring for a private chart type
# registry mirror.

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart_dir="$repo_dir/charts/lightdash"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
    printf 'chart registry rendering check failed: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local value="$2"
    grep -Fq -- "$value" "$file" || fail "expected '$value' in $file"
}

assert_not_contains() {
    local file="$1"
    local value="$2"
    if grep -Fq -- "$value" "$file"; then
        fail "did not expect '$value' in $file"
    fi
}

extract_source() {
    local source="$1"
    local input="$2"
    local output="$3"
    awk -v source="# Source: $source" '$0 == source { capture = 1; next } capture && /^---$/ { exit } capture { print }' "$input" > "$output"
}

render() {
    local output="$1"
    shift
    helm template registry "$chart_dir" \
        --namespace registry-ns \
        --set postgresql.enabled=false \
        --set browserless-chrome.enabled=false \
        --set nats.enabled=false \
        --set s3.endpoint=http://object-store \
        --set s3.bucket=test \
        --set s3.region=local \
        "$@" > "$output"
}

header_env='- name: LIGHTDASH_CHART_REGISTRY_AUTHORIZATION_HEADER'

# Defaults: nothing registry-related is rendered, so a plain install keeps the
# application defaults (official registry, strict SSRF checks, no credentials).
default_render="$temp_dir/default.yaml"
render "$default_render"
assert_not_contains "$default_render" 'LIGHTDASH_CHART_REGISTRY_URL'
assert_not_contains "$default_render" 'LIGHTDASH_CHART_REGISTRY_ALLOW_PRIVATE_HOSTS'
assert_not_contains "$default_render" 'LIGHTDASH_CHART_REGISTRY_AUTHORIZATION_HEADER'

# A private mirror: URL and the private-hosts flag land in the ConfigMap, the
# Authorization header is read from the operator's Secret with secretKeyRef on
# the backend and on every worker, and the header value itself never appears in
# the rendered manifests.
mirror_render="$temp_dir/mirror.yaml"
render "$mirror_render" \
    --set scheduler.enabled=true \
    --set migrationJob.enabled=true \
    --set chartRegistry.url=https://charts.internal.example/lightdash \
    --set chartRegistry.allowPrivateHosts=true \
    --set chartRegistry.existingSecret=registry-auth \
    --set chartRegistry.secretKey=authorization

configmap="$temp_dir/configmap.yaml"
extract_source lightdash/templates/configmap.yaml "$mirror_render" "$configmap"
assert_contains "$configmap" 'LIGHTDASH_CHART_REGISTRY_URL: "https://charts.internal.example/lightdash"'
assert_contains "$configmap" 'LIGHTDASH_CHART_REGISTRY_ALLOW_PRIVATE_HOSTS: "true"'
assert_not_contains "$configmap" 'LIGHTDASH_CHART_REGISTRY_AUTHORIZATION_HEADER'

expected_header_env='            - name: LIGHTDASH_CHART_REGISTRY_AUTHORIZATION_HEADER
              valueFrom:
                secretKeyRef:
                  name: registry-auth
                  key: authorization'

assert_header_env() {
    local source="$1"
    local manifest="$temp_dir/workload.yaml"
    extract_source "$source" "$mirror_render" "$manifest"
    [[ -s "$manifest" ]] || fail "no manifest rendered for $source"
    local actual
    actual="$(grep -F -A4 -- "$header_env" "$manifest" || true)"
    if [[ "$actual" != "$expected_header_env" ]]; then
        printf '%s\n' "$actual" >&2
        fail "unexpected Authorization header env in $source"
    fi
}

assert_header_env lightdash/templates/backendDeployment.yaml
assert_header_env lightdash/templates/workerDeployment.yaml

migration_job="$temp_dir/migration.yaml"
extract_source lightdash/templates/migrationJob.yaml "$mirror_render" "$migration_job"
[[ -s "$migration_job" ]] || fail "no migration Job rendered"
assert_not_contains "$migration_job" 'LIGHTDASH_CHART_REGISTRY_AUTHORIZATION_HEADER'

# The Secret key defaults to the environment variable name, so a Secret keyed
# the way Lightdash spells it needs no extra value.
default_key_render="$temp_dir/default-key.yaml"
render "$default_key_render" --set chartRegistry.existingSecret=registry-auth
backend="$temp_dir/backend.yaml"
extract_source lightdash/templates/backendDeployment.yaml "$default_key_render" "$backend"
assert_contains "$backend" '                  key: LIGHTDASH_CHART_REGISTRY_AUTHORIZATION_HEADER'
assert_not_contains "$default_key_render" 'LIGHTDASH_CHART_REGISTRY_ALLOW_PRIVATE_HOSTS'

# allowPrivateHosts=false must not render the flag at all rather than render
# "false", so an operator who later sets it in configMap gets no duplicate key.
explicit_false_render="$temp_dir/explicit-false.yaml"
render "$explicit_false_render" --set chartRegistry.allowPrivateHosts=false
assert_not_contains "$explicit_false_render" 'LIGHTDASH_CHART_REGISTRY_ALLOW_PRIVATE_HOSTS'

printf 'chart registry rendering check passed\n'
