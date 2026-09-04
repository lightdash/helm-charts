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

render() {
    local output="$1"
    local lifecycle="$2"
    shift 2
    local args=(
        safety "$chart_dir"
        --namespace safety-ns
        --set postgresql.enabled=false
        --set browserless-chrome.enabled=false
        --set nats.enabled=false
        --set s3.endpoint=http://object-store
        --set s3.bucket=test
        --set s3.region=local
        "$@"
    )
    if [[ "$lifecycle" == "upgrade" ]]; then
        args+=(--is-upgrade)
    fi
    helm template "${args[@]}" > "$output"
}

assert_strategy() {
    local render_file="$1"
    local source="$2"
    local strategy_type="$3"
    local manifest="$temp_dir/deployment.yaml"
    extract_source "$source" "$render_file" "$manifest"
    assert_contains "$manifest" '  strategy:'
    assert_contains "$manifest" "    type: $strategy_type"
}

assert_no_strategy() {
    local render_file="$1"
    local source="$2"
    local manifest="$temp_dir/deployment.yaml"
    extract_source "$source" "$render_file" "$manifest"
    assert_not_contains "$manifest" '  strategy:'
}

assert_no_rolling_update() {
    local render_file="$1"
    local source="$2"
    local manifest="$temp_dir/deployment.yaml"
    extract_source "$source" "$render_file" "$manifest"
    assert_not_contains "$manifest" '    rollingUpdate:'
}

assert_tuning() {
    local render_file="$1"
    local source="$2"
    local value="$3"
    local manifest="$temp_dir/deployment.yaml"
    extract_source "$source" "$render_file" "$manifest"
    assert_contains "$manifest" '    rollingUpdate:'
    assert_contains "$manifest" "      maxSurge: $value"
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

assert_scale_down() {
    local render_file="$1"
    local job="$temp_dir/job.yaml"
    local role="$temp_dir/role.yaml"
    local role_binding="$temp_dir/role-binding.yaml"
    local service_account="$temp_dir/service-account.yaml"
    extract_source lightdash/templates/migrationJob.yaml "$render_file" "$job"
    extract_source lightdash/templates/migrationScaleDownRbac.yaml "$render_file" "$role"
    extract_kind RoleBinding "$render_file" "$role_binding"
    extract_source lightdash/templates/migrationServiceAccount.yaml "$render_file" "$service_account"
    assert_contains "$job" 'name: remove-backend-hpa'
    assert_contains "$job" 'name: scale-down-workloads'
    assert_contains "$job" 'name: wait-for-workload-termination'
    assert_contains "$job" '--replicas=0'
    assert_contains "$job" 'app.kubernetes.io/component in (backend,worker,app-build-worker,warehouse-nats-worker,pre-aggregate-nats-worker)'
    assert_not_contains "$job" 'app.kubernetes.io/component=migration'
    assert_contains "$job" 'serviceAccountName: safety-lightdash-migration'
    assert_contains "$role" 'kind: Role'
    assert_not_contains "$role" 'kind: ClusterRole'
    assert_contains "$role" 'helm.sh/hook: pre-upgrade'
    assert_contains "$role" 'helm.sh/hook-weight: "-3"'
    assert_contains "$role" 'helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed'
    assert_contains "$service_account" 'helm.sh/hook: pre-install,pre-upgrade'
    assert_contains "$service_account" 'helm.sh/hook-weight: "-2"'
    assert_contains "$role_binding" 'helm.sh/hook: pre-upgrade'
    assert_contains "$role_binding" 'helm.sh/hook-weight: "-1"'
    assert_contains "$role_binding" 'helm.sh/hook-delete-policy: before-hook-creation,hook-succeeded,hook-failed'
    assert_contains "$role_binding" 'name: safety-lightdash-migration'
    assert_contains "$role_binding" 'namespace: safety-ns'
    local actual_rules
    actual_rules="$(awk '/^rules:$/ { capture = 1 } capture { print }' "$role")"
    if ! diff -u <(printf '%s\n' "$expected_rules") <(printf '%s\n' "$actual_rules"); then
        fail "rendered unexpected RBAC rules"
    fi
}

assert_no_scale_down() {
    local render_file="$1"
    assert_not_contains "$render_file" 'name: safety-lightdash-migration-scale-down'
    assert_not_contains "$render_file" 'name: remove-backend-hpa'
    assert_not_contains "$render_file" 'name: scale-down-workloads'
    assert_not_contains "$render_file" 'name: wait-for-workload-termination'
}

assert_migration_identity() {
    local render_file="$1"
    local job="$temp_dir/job.yaml"
    local service_account="$temp_dir/service-account.yaml"
    extract_source lightdash/templates/migrationJob.yaml "$render_file" "$job"
    extract_source lightdash/templates/migrationServiceAccount.yaml "$render_file" "$service_account"
    assert_contains "$job" 'serviceAccountName: safety-lightdash-migration'
    assert_contains "$service_account" 'name: safety-lightdash-migration'
    assert_contains "$service_account" 'helm.sh/hook: pre-install,pre-upgrade'
    assert_contains "$service_account" 'helm.sh/hook-weight: "-2"'
}

deployment_sources=(
    lightdash/templates/backendDeployment.yaml
    lightdash/templates/workerDeployment.yaml
    lightdash/templates/appBuildWorkerDeployment.yaml
    lightdash/templates/warehouseNatsWorkerDeployment.yaml
    lightdash/templates/preAggregateNatsWorkerDeployment.yaml
)

for lifecycle in install upgrade; do
    for mode in unset RollingUpdate Recreate; do
        output="$temp_dir/mode-${mode}-${lifecycle}.yaml"
        mode_value=""
        if [[ "$mode" != "unset" ]]; then
            mode_value="$mode"
        fi
        render "$output" "$lifecycle" \
            --set-string upgrade.mode="$mode_value" \
            --set migrationJob.enabled=true \
            --set autoscaling.enabled=true \
            --set autoscaling.minReplicas=3 \
            --set scheduler.enabled=true \
            --set appBuildWorker.enabled=true \
            --set warehouseNatsWorker.enabled=true \
            --set preAggregateNatsWorker.enabled=true

        for source in "${deployment_sources[@]}"; do
            if [[ "$mode" == "unset" ]]; then
                assert_no_strategy "$output" "$source"
            else
                assert_strategy "$output" "$source" "$mode"
            fi
            if [[ "$mode" == "Recreate" ]]; then
                assert_no_rolling_update "$output" "$source"
            fi
        done

        backend="$temp_dir/backend.yaml"
        extract_source lightdash/templates/backendDeployment.yaml "$output" "$backend"
        assert_migration_identity "$output"
        if [[ "$lifecycle" == "upgrade" && "$mode" == "Recreate" ]]; then
            assert_scale_down "$output"
            assert_contains "$backend" '  replicas: 3'
        else
            assert_no_scale_down "$output"
            assert_not_contains "$backend" '  replicas:'
        fi
    done
done

legacy_components=(
    lightdashBackend
    scheduler
    appBuildWorker
    warehouseNatsWorker
    preAggregateNatsWorker
)

for component in "${legacy_components[@]}"; do
    output="$temp_dir/legacy-${component}.yaml"
    args=(
        --set migrationJob.enabled=true
        --set "$component.strategy.type=Recreate"
    )
    if [[ "$component" != "lightdashBackend" ]]; then
        args+=(--set "$component.enabled=true")
    fi
    render "$output" upgrade "${args[@]}"
    assert_scale_down "$output"
done

disabled_legacy="$temp_dir/disabled-legacy.yaml"
render "$disabled_legacy" upgrade \
    --set migrationJob.enabled=true \
    --set scheduler.enabled=false \
    --set scheduler.strategy.type=Recreate
assert_no_scale_down "$disabled_legacy"

legacy_preserved="$temp_dir/legacy-preserved.yaml"
render "$legacy_preserved" upgrade \
    --set migrationJob.enabled=true \
    --set scheduler.enabled=true \
    --set appBuildWorker.enabled=true \
    --set warehouseNatsWorker.enabled=true \
    --set preAggregateNatsWorker.enabled=true \
    --set lightdashBackend.strategy.type=RollingUpdate \
    --set lightdashBackend.strategy.rollingUpdate.maxSurge=11 \
    --set scheduler.strategy.type=Recreate \
    --set appBuildWorker.strategy.type=RollingUpdate \
    --set appBuildWorker.strategy.rollingUpdate.maxSurge=12 \
    --set warehouseNatsWorker.strategy.type=RollingUpdate \
    --set warehouseNatsWorker.strategy.rollingUpdate.maxSurge=13
assert_strategy "$legacy_preserved" lightdash/templates/backendDeployment.yaml RollingUpdate
assert_tuning "$legacy_preserved" lightdash/templates/backendDeployment.yaml 11
assert_strategy "$legacy_preserved" lightdash/templates/workerDeployment.yaml Recreate
assert_no_rolling_update "$legacy_preserved" lightdash/templates/workerDeployment.yaml
assert_strategy "$legacy_preserved" lightdash/templates/appBuildWorkerDeployment.yaml RollingUpdate
assert_tuning "$legacy_preserved" lightdash/templates/appBuildWorkerDeployment.yaml 12
assert_strategy "$legacy_preserved" lightdash/templates/warehouseNatsWorkerDeployment.yaml RollingUpdate
assert_tuning "$legacy_preserved" lightdash/templates/warehouseNatsWorkerDeployment.yaml 13
assert_no_strategy "$legacy_preserved" lightdash/templates/preAggregateNatsWorkerDeployment.yaml
assert_scale_down "$legacy_preserved"

rolling_override="$temp_dir/rolling-override.yaml"
render "$rolling_override" upgrade \
    --set upgrade.mode=RollingUpdate \
    --set migrationJob.enabled=true \
    --set scheduler.enabled=true \
    --set appBuildWorker.enabled=true \
    --set warehouseNatsWorker.enabled=true \
    --set preAggregateNatsWorker.enabled=true \
    --set lightdashBackend.strategy.type=Recreate \
    --set lightdashBackend.strategy.rollingUpdate.maxSurge=21 \
    --set scheduler.strategy.type=Recreate \
    --set scheduler.strategy.rollingUpdate.maxSurge=22 \
    --set appBuildWorker.strategy.type=Recreate \
    --set appBuildWorker.strategy.rollingUpdate.maxSurge=23 \
    --set warehouseNatsWorker.strategy.type=Recreate \
    --set warehouseNatsWorker.strategy.rollingUpdate.maxSurge=24 \
    --set preAggregateNatsWorker.strategy.type=Recreate \
    --set preAggregateNatsWorker.strategy.rollingUpdate.maxSurge=25
surge=21
for source in "${deployment_sources[@]}"; do
    assert_strategy "$rolling_override" "$source" RollingUpdate
    assert_tuning "$rolling_override" "$source" "$surge"
    surge=$((surge + 1))
done
assert_no_scale_down "$rolling_override"

recreate_override="$temp_dir/recreate-override.yaml"
render "$recreate_override" upgrade \
    --set upgrade.mode=Recreate \
    --set migrationJob.enabled=true \
    --set scheduler.enabled=true \
    --set appBuildWorker.enabled=true \
    --set warehouseNatsWorker.enabled=true \
    --set preAggregateNatsWorker.enabled=true \
    --set lightdashBackend.strategy.rollingUpdate.maxSurge=31 \
    --set scheduler.strategy.rollingUpdate.maxSurge=32 \
    --set appBuildWorker.strategy.rollingUpdate.maxSurge=33 \
    --set warehouseNatsWorker.strategy.rollingUpdate.maxSurge=34 \
    --set preAggregateNatsWorker.strategy.rollingUpdate.maxSurge=35
for source in "${deployment_sources[@]}"; do
    assert_strategy "$recreate_override" "$source" Recreate
    assert_no_rolling_update "$recreate_override" "$source"
done
assert_scale_down "$recreate_override"

for mask in {0..15}; do
    scheduler_enabled=false
    app_build_enabled=false
    warehouse_enabled=false
    pre_aggregate_enabled=false
    ((mask & 1)) && scheduler_enabled=true
    ((mask & 2)) && app_build_enabled=true
    ((mask & 4)) && warehouse_enabled=true
    ((mask & 8)) && pre_aggregate_enabled=true
    output="$temp_dir/workers-${mask}.yaml"
    render "$output" upgrade \
        --set upgrade.mode=Recreate \
        --set migrationJob.enabled=true \
        --set scheduler.enabled="$scheduler_enabled" \
        --set appBuildWorker.enabled="$app_build_enabled" \
        --set warehouseNatsWorker.enabled="$warehouse_enabled" \
        --set preAggregateNatsWorker.enabled="$pre_aggregate_enabled"
    expected_count=$((1 + (mask & 1) + ((mask >> 1) & 1) + ((mask >> 2) & 1) + ((mask >> 3) & 1)))
    actual_count="$(grep -c '^kind: Deployment$' "$output" || true)"
    [[ "$actual_count" == "$expected_count" ]] || fail "worker mask $mask rendered $actual_count Deployments instead of $expected_count"
    assert_scale_down "$output"
done

migration_off="$temp_dir/migration-off.yaml"
render "$migration_off" upgrade \
    --set upgrade.mode=Recreate \
    --set migrationJob.enabled=false \
    --set autoscaling.enabled=true \
    --set scheduler.enabled=true \
    --set appBuildWorker.enabled=true \
    --set warehouseNatsWorker.enabled=true \
    --set preAggregateNatsWorker.enabled=true
assert_no_scale_down "$migration_off"
assert_not_contains "$migration_off" 'name: safety-lightdash-migrate'
for source in "${deployment_sources[@]}"; do
    assert_strategy "$migration_off" "$source" Recreate
done
backend="$temp_dir/backend.yaml"
extract_source lightdash/templates/backendDeployment.yaml "$migration_off" "$backend"
assert_not_contains "$backend" '  replicas:'

custom_rbac="$temp_dir/custom-rbac.yaml"
render "$custom_rbac" upgrade \
    --set upgrade.mode=Recreate \
    --set migrationJob.enabled=true \
    --set migrationJob.scaleDownWorkloads.rbac.create=false \
    --set migrationJob.serviceAccount.create=false \
    --set migrationJob.serviceAccount.name=existing-migrator
assert_not_contains "$custom_rbac" 'name: safety-lightdash-migration-scale-down'
job="$temp_dir/job.yaml"
extract_source lightdash/templates/migrationJob.yaml "$custom_rbac" "$job"
assert_contains "$job" 'serviceAccountName: existing-migrator'
assert_contains "$job" 'name: scale-down-workloads'

invalid_output="$temp_dir/invalid.yaml"
invalid_error="$temp_dir/invalid.err"
if render "$invalid_output" upgrade --set upgrade.mode=BlueGreen 2> "$invalid_error"; then
    fail "invalid upgrade.mode rendered successfully"
fi
assert_contains "$invalid_error" 'upgrade.mode must be one of: RollingUpdate, Recreate'

removed_key="migrationJob.scaleDownWorkloads."'enabled'
if grep -R -Fq -- "$removed_key" "$chart_dir"; then
    fail "removed scale-down enabled key is still present"
fi

printf 'migration scale-down rendering checks passed\n'
