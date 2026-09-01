#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart_dir="$repo_dir/charts/lightdash"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

fail() {
    printf 'migration scale-down rendering check failed: %s\n' "$1" >&2
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

extract_kind() {
    local kind="$1"
    local input="$2"
    local output="$3"
    awk -v expected_kind="kind: $kind" '
        function emit() {
            if (found) {
                printf "%s", document
                emitted = 1
                exit
            }
        }
        /^---$/ {
            emit()
            document = ""
            found = 0
            next
        }
        {
            document = document $0 ORS
            if ($0 == expected_kind) {
                found = 1
            }
        }
        END {
            if (found && !emitted) {
                printf "%s", document
            }
        }
    ' "$input" > "$output"
}

expected_rules='rules:
  - apiGroups:
      - apps
    resources:
      - deployments
    verbs:
      - list
  - apiGroups:
      - apps
    resources:
      - deployments/scale
    resourceNames:
      - safety-lightdash-backend
      - safety-lightdash-worker
      - safety-lightdash-app-build-worker
      - safety-lightdash-warehouse-nats-worker
      - safety-lightdash-pre-aggregate-nats-worker
    verbs:
      - patch
  - apiGroups:
      - autoscaling
    resources:
      - horizontalpodautoscalers
    resourceNames:
      - safety-lightdash
    verbs:
      - delete
      - get
  - apiGroups:
      - ""
    resources:
      - pods
    verbs:
      - get
      - list
      - watch'

render_case() {
    local scale_down="$1"
    local lifecycle="$2"
    local autoscaling="$3"
    local workers="$4"
    local case_name="scale-${scale_down}_${lifecycle}_autoscaling-${autoscaling}_workers-${workers}"
    local render="$temp_dir/${case_name}.yaml"
    local job="$temp_dir/${case_name}-job.yaml"
    local backend="$temp_dir/${case_name}-backend.yaml"
    local rbac="$temp_dir/${case_name}-rbac.yaml"
    local role_binding="$temp_dir/${case_name}-role-binding.yaml"
    local service_account="$temp_dir/${case_name}-service-account.yaml"
    local helm_args=(
        safety "$chart_dir"
        --namespace safety-ns
        --set postgresql.enabled=false
        --set browserless-chrome.enabled=false
        --set nats.enabled=false
        --set s3.endpoint=http://object-store
        --set s3.bucket=test
        --set s3.region=local
        --set migrationJob.enabled=true
        --set migrationJob.scaleDownWorkloads.enabled="$scale_down"
        --set autoscaling.enabled="$autoscaling"
        --set autoscaling.minReplicas=3
        --set replicaCount=2
        --set scheduler.enabled="$workers"
        --set appBuildWorker.enabled="$workers"
        --set warehouseNatsWorker.enabled="$workers"
        --set preAggregateNatsWorker.enabled="$workers"
    )

    if [[ "$lifecycle" == "upgrade" ]]; then
        helm_args+=(--is-upgrade)
    fi

    helm template "${helm_args[@]}" > "$render"
    extract_source lightdash/templates/migrationJob.yaml "$render" "$job"
    extract_source lightdash/templates/backendDeployment.yaml "$render" "$backend"

    local deployment_count
    deployment_count="$(grep -c '^kind: Deployment$' "$render" || true)"
    if [[ "$workers" == "true" && "$deployment_count" != "5" ]]; then
        fail "$case_name rendered $deployment_count Deployments instead of 5"
    fi
    if [[ "$workers" == "false" && "$deployment_count" != "1" ]]; then
        fail "$case_name rendered $deployment_count Deployments instead of 1"
    fi

    if [[ "$autoscaling" == "false" ]]; then
        assert_contains "$backend" '  replicas: 2'
    elif [[ "$scale_down" == "true" && "$lifecycle" == "upgrade" ]]; then
        assert_contains "$backend" '  replicas: 3'
    else
        assert_not_contains "$backend" '  replicas:'
    fi

    if [[ "$scale_down" == "true" && "$lifecycle" == "upgrade" ]]; then
        extract_source lightdash/templates/migrationScaleDownRbac.yaml "$render" "$rbac"
        extract_kind RoleBinding "$render" "$role_binding"
        extract_source lightdash/templates/migrationServiceAccount.yaml "$render" "$service_account"
        assert_contains "$render" 'name: safety-lightdash-migration-scale-down'
        assert_contains "$rbac" 'kind: Role'
        assert_not_contains "$rbac" 'kind: ClusterRole'
        assert_contains "$render" 'helm.sh/hook-weight: "-3"'
        assert_contains "$render" 'helm.sh/hook: pre-upgrade'
        assert_contains "$rbac" 'helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed'
        assert_contains "$service_account" 'helm.sh/hook-weight: "-2"'
        assert_contains "$service_account" 'helm.sh/hook: pre-install,pre-upgrade'
        assert_contains "$role_binding" 'helm.sh/hook-weight: "-1"'
        assert_contains "$role_binding" 'helm.sh/hook: pre-upgrade'
        assert_contains "$role_binding" 'helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed'
        assert_contains "$role_binding" 'name: safety-lightdash-migration'
        assert_contains "$role_binding" 'namespace: safety-ns'
        assert_contains "$job" 'helm.sh/hook-weight: "0"'
        assert_contains "$job" 'serviceAccountName: safety-lightdash-migration'
        assert_contains "$job" 'name: remove-backend-hpa'
        assert_contains "$job" 'name: scale-down-workloads'
        assert_contains "$job" 'name: wait-for-workload-termination'
        assert_contains "$job" '--replicas=0'
        assert_contains "$job" 'app.kubernetes.io/component in (backend,worker,app-build-worker,warehouse-nats-worker,pre-aggregate-nats-worker)'
        assert_not_contains "$job" 'app.kubernetes.io/component=migration'

        local actual_rules
        actual_rules="$(awk '/^rules:$/ { capture = 1 } capture { print }' "$rbac")"
        if ! diff -u <(printf '%s\n' "$expected_rules") <(printf '%s\n' "$actual_rules"); then
            fail "$case_name rendered unexpected RBAC rules"
        fi

    else
        assert_not_contains "$render" 'name: safety-lightdash-migration-scale-down'
        assert_not_contains "$job" 'name: scale-down-workloads'
        assert_not_contains "$job" 'name: wait-for-workload-termination'
    fi
}

for scale_down in false true; do
    for lifecycle in install upgrade; do
        for autoscaling in false true; do
            for workers in false true; do
                render_case "$scale_down" "$lifecycle" "$autoscaling" "$workers"
            done
        done
    done
done

custom_render="$temp_dir/custom-service-account.yaml"
custom_job="$temp_dir/custom-service-account-job.yaml"
helm template safety "$chart_dir" --is-upgrade \
    --namespace safety-ns \
    --set postgresql.enabled=false \
    --set browserless-chrome.enabled=false \
    --set nats.enabled=false \
    --set s3.endpoint=http://object-store \
    --set s3.bucket=test \
    --set s3.region=local \
    --set migrationJob.enabled=true \
    --set migrationJob.scaleDownWorkloads.enabled=true \
    --set migrationJob.scaleDownWorkloads.rbac.create=false \
    --set migrationJob.serviceAccount.create=false \
    --set migrationJob.serviceAccount.name=existing-migrator > "$custom_render"
extract_source lightdash/templates/migrationJob.yaml "$custom_render" "$custom_job"
assert_not_contains "$custom_render" 'name: safety-lightdash-migration-scale-down'
assert_contains "$custom_job" 'serviceAccountName: existing-migrator'
assert_contains "$custom_job" 'name: scale-down-workloads'

disabled_render="$temp_dir/migration-disabled.yaml"
helm template safety "$chart_dir" --is-upgrade \
    --set postgresql.enabled=false \
    --set browserless-chrome.enabled=false \
    --set nats.enabled=false \
    --set s3.endpoint=http://object-store \
    --set s3.bucket=test \
    --set s3.region=local \
    --set migrationJob.enabled=false \
    --set migrationJob.scaleDownWorkloads.enabled=true > "$disabled_render"
assert_not_contains "$disabled_render" 'name: safety-lightdash-migration-scale-down'
assert_not_contains "$disabled_render" 'name: safety-lightdash-migrate'

printf 'migration scale-down rendering checks passed\n'
