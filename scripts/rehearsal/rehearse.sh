#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CHART="$REPO_ROOT/charts/lightdash"
DEFAULT_VALUES="$SCRIPT_DIR/values/rehearsal.yaml"

FROM_SOURCE="latest"
TO_SOURCE="local"
FROM_EXPLICIT=false
ALLOW_NON_FORWARD=false
VALUES_FILE="$DEFAULT_VALUES"
VALUES_EXPLICIT=false
INSTALL_ONLY=false
DRILL=""
CLUSTER_NAME="lightdash-rehearsal"
KIND_IMAGE=""
SKIP_CLUSTER=false
KEEP_CLUSTER=false
ALLOWED_DROPS=0

RELEASE_NAME="lightdash"
NAMESPACE="default"
APP_DB_PASSWORD="rehearsal-postgres-password"
POSTGRES_PASSWORD="rehearsal-postgres-superuser-password"
USER_EMAIL=""
USER_PASSWORD="Rehearsal1!"
RUN_ID=""
CLIENT_POD=""
TRAFFIC_POD=""
TEMP_DIR=""
OVERLAY_FILE=""
CLUSTER_CREATED=false
TRAFFIC_CREATED=false
CLIENT_CREATED=false
DDL_TRIGGER_INSTALLED=false
SUMMARY_PRINTED=false
LAST_ERROR=""
CURRENT_STEP="argument parsing"
MIGRATION_BEFORE=""
MIGRATION_COUNT_BEFORE=0
LEDGER_EXISTED_BEFORE=false
LEDGER_COUNT_BEFORE=0
UPGRADE_START_EPOCH=0
UPGRADE_END_EPOCH=0
ROLLOUT_OBSERVER_PID=""
ROLLOUT_OBSERVER_FILE=""
ROLLOUT_DEPLOYMENT_BEFORE=""
ROLLOUT_DEPLOYMENT_AFTER=""
POSTGRES_POD_UID_BEFORE=""
POSTGRES_POD_UID_AFTER=""
DRAIN_APP_NODE=""
DRAIN_DB_NODE=""

declare -a SUMMARY_STATES=()
declare -a SUMMARY_NAMES=()
declare -a SUMMARY_DETAILS=()

usage() {
    printf '%s\n' \
        "Usage: scripts/rehearsal/rehearse.sh [options]" \
        "" \
        "  --from <chart-version|latest>" \
        "  --to <chart-version|local>" \
        "  --allow-non-forward" \
        "  --values <file>" \
        "  --install-only" \
        "  --drill <parked-migration|killed-migrator|slow-migration|drain>" \
        "  --cluster-name <name>" \
        "  --kind-image <kindest/node:vX.Y.Z>" \
        "  --skip-cluster" \
        "  --keep" \
        "  --allowed-drops <n>" \
        "  -h, --help"
}

record_result() {
    local state="$1"
    local name="$2"
    local detail="$3"
    SUMMARY_STATES+=("$state")
    SUMMARY_NAMES+=("$name")
    SUMMARY_DETAILS+=("$detail")
    printf '%s: %s (%s)\n' "$state" "$name" "$detail"
}

has_failure() {
    local state
    for state in "${SUMMARY_STATES[@]}"; do
        if [[ "$state" == "FAIL" ]]; then
            return 0
        fi
    done
    return 1
}

print_summary() {
    local index
    local result="PASS"
    if has_failure; then
        result="FAIL"
    fi
    printf '\n=== Rehearsal summary ===\n'
    for ((index = 0; index < ${#SUMMARY_NAMES[@]}; index += 1)); do
        printf '%s: %s (%s)\n' "${SUMMARY_STATES[$index]}" "${SUMMARY_NAMES[$index]}" "${SUMMARY_DETAILS[$index]}"
    done
    printf 'RESULT: %s\n' "$result"
    SUMMARY_PRINTED=true
}

fail() {
    record_result "FAIL" "$1" "$2"
    exit 1
}

on_error() {
    local status=$?
    LAST_ERROR="$CURRENT_STEP failed at line ${BASH_LINENO[0]}: $BASH_COMMAND"
    return "$status"
}

psql_app() {
    local sql="$1"
    kubectl exec -n "$NAMESPACE" "$RELEASE_NAME-postgresql-0" -- env PGPASSWORD="$APP_DB_PASSWORD" psql -v ON_ERROR_STOP=1 -U lightdash -d lightdash -Atq -c "$sql"
}

psql_superuser() {
    local sql="$1"
    kubectl exec -n "$NAMESPACE" "$RELEASE_NAME-postgresql-0" -- env PGPASSWORD="$POSTGRES_PASSWORD" psql -v ON_ERROR_STOP=1 -U postgres -d lightdash -Atq -c "$sql"
}

remove_ddl_trigger() {
    if [[ "$DDL_TRIGGER_INSTALLED" != "true" ]]; then
        return
    fi
    psql_superuser "DROP EVENT TRIGGER IF EXISTS rehearsal_ddl_guard; DROP FUNCTION IF EXISTS rehearsal_ddl_guard(); DROP TABLE IF EXISTS rehearsal_ddl_trigger_state;" >/dev/null 2>&1 || true
    DDL_TRIGGER_INSTALLED=false
}

cleanup() {
    set +e
    remove_ddl_trigger
    stop_rollout_observer
    if [[ "$TRAFFIC_CREATED" == "true" ]]; then
        kubectl delete pod -n "$NAMESPACE" "$TRAFFIC_POD" --ignore-not-found --wait=false >/dev/null 2>&1
    fi
    if [[ "$CLIENT_CREATED" == "true" ]]; then
        kubectl delete pod -n "$NAMESPACE" "$CLIENT_POD" --ignore-not-found --wait=false >/dev/null 2>&1
    fi
    if [[ "$CLUSTER_CREATED" == "true" && "$KEEP_CLUSTER" != "true" ]]; then
        kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
    fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

on_exit() {
    local status=$?
    trap - ERR EXIT
    if ((status != 0)) && ! has_failure; then
        if [[ -z "$LAST_ERROR" ]]; then
            LAST_ERROR="$CURRENT_STEP stopped unexpectedly"
        fi
        record_result "FAIL" "Harness execution" "$LAST_ERROR"
    fi
    if [[ "$SUMMARY_PRINTED" != "true" ]]; then
        print_summary
    fi
    cleanup
    if has_failure; then
        exit 1
    fi
    exit "$status"
}

trap on_error ERR
trap on_exit EXIT

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        printf 'Missing value for %s\n' "$option" >&2
        usage >&2
        exit 2
    fi
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --from)
                require_value "$1" "${2:-}"
                FROM_SOURCE="$2"
                FROM_EXPLICIT=true
                shift 2
                ;;
            --to)
                require_value "$1" "${2:-}"
                TO_SOURCE="$2"
                shift 2
                ;;
            --allow-non-forward)
                ALLOW_NON_FORWARD=true
                shift
                ;;
            --values)
                require_value "$1" "${2:-}"
                VALUES_FILE="$2"
                VALUES_EXPLICIT=true
                shift 2
                ;;
            --install-only)
                INSTALL_ONLY=true
                shift
                ;;
            --drill)
                require_value "$1" "${2:-}"
                DRILL="$2"
                shift 2
                ;;
            --cluster-name)
                require_value "$1" "${2:-}"
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --kind-image)
                require_value "$1" "${2:-}"
                KIND_IMAGE="$2"
                shift 2
                ;;
            --skip-cluster)
                SKIP_CLUSTER=true
                shift
                ;;
            --keep)
                KEEP_CLUSTER=true
                shift
                ;;
            --allowed-drops)
                require_value "$1" "${2:-}"
                ALLOWED_DROPS="$2"
                shift 2
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                printf 'Unknown option: %s\n' "$1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done
}

canonical_path() {
    local path="$1"
    local directory
    local filename
    directory="$(cd "$(dirname "$path")" && pwd)"
    filename="$(basename "$path")"
    printf '%s/%s\n' "$directory" "$filename"
}

validate_args() {
    local canonical_values
    local canonical_default
    if [[ "$INSTALL_ONLY" == "true" && -n "$DRILL" ]]; then
        printf '%s\n' "--install-only and --drill are mutually exclusive" >&2
        exit 2
    fi
    case "$DRILL" in
        "" | parked-migration | killed-migrator | slow-migration | drain) ;;
        *)
            printf 'Unknown drill: %s\n' "$DRILL" >&2
            exit 2
            ;;
    esac
    if [[ ! "$ALLOWED_DROPS" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "--allowed-drops must be a non-negative integer" >&2
        exit 2
    fi
    if [[ ! -f "$VALUES_FILE" ]]; then
        printf 'Values file does not exist: %s\n' "$VALUES_FILE" >&2
        exit 2
    fi
    if [[ -n "$DRILL" && "$VALUES_EXPLICIT" == "true" ]]; then
        canonical_values="$(canonical_path "$VALUES_FILE")"
        canonical_default="$(canonical_path "$DEFAULT_VALUES")"
        if [[ "$canonical_values" != "$canonical_default" ]]; then
            printf '%s\n' "--drill cannot be combined with a custom --values file" >&2
            exit 2
        fi
    fi
}

preflight() {
    local tool
    local -a tools=(kubectl helm jq)
    if [[ "$SKIP_CLUSTER" != "true" ]]; then
        tools+=(kind docker)
    fi
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "Preflight" "missing required tool: $tool"
        fi
    done
    if [[ "$SKIP_CLUSTER" != "true" ]] && ! docker info >/dev/null 2>&1; then
        fail "Preflight" "docker is installed but the daemon is unavailable"
    fi
    record_result "PASS" "Preflight" "all required tools are available"
}

create_cluster() {
    local -a command=(kind create cluster --name "$CLUSTER_NAME")
    if [[ "$SKIP_CLUSTER" == "true" ]]; then
        record_result "SKIP" "Kind cluster" "using the current kubectl context"
        return
    fi
    if [[ -n "$KIND_IMAGE" ]]; then
        command+=(--image "$KIND_IMAGE")
    fi
    if [[ "$DRILL" == "drain" ]]; then
        cat >"$TEMP_DIR/kind.yaml" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
YAML
        command+=(--config "$TEMP_DIR/kind.yaml")
    fi
    CLUSTER_CREATED=true
    "${command[@]}"
    record_result "PASS" "Kind cluster" "created $CLUSTER_NAME"
}

deploy_minio() {
    kubectl delete job -n "$NAMESPACE" rehearsal-minio-bucket --ignore-not-found >/dev/null
    kubectl apply -n "$NAMESPACE" -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  labels:
    app: rehearsal-minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rehearsal-minio
  template:
    metadata:
      labels:
        app: rehearsal-minio
    spec:
      containers:
        - name: minio
          image: minio/minio:latest
          args:
            - server
            - /data
          env:
            - name: MINIO_ROOT_USER
              value: rehearsal-minio
            - name: MINIO_ROOT_PASSWORD
              value: rehearsal-minio-password
          ports:
            - name: api
              containerPort: 9000
          readinessProbe:
            httpGet:
              path: /minio/health/ready
              port: api
            periodSeconds: 2
            failureThreshold: 60
          volumeMounts:
            - name: data
              mountPath: /data
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: rehearsal-minio
  ports:
    - name: api
      port: 9000
      targetPort: api
YAML
    kubectl rollout status -n "$NAMESPACE" deployment/minio --timeout=5m
    kubectl apply -n "$NAMESPACE" -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: rehearsal-minio-bucket
spec:
  backoffLimit: 6
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: bucket
          image: minio/mc:latest
          command:
            - /bin/sh
            - -c
          args:
            - mc alias set rehearsal http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mb -p rehearsal/lightdash
          env:
            - name: MINIO_ROOT_USER
              value: rehearsal-minio
            - name: MINIO_ROOT_PASSWORD
              value: rehearsal-minio-password
YAML
    kubectl wait -n "$NAMESPACE" --for=condition=complete job/rehearsal-minio-bucket --timeout=5m
    record_result "PASS" "Object storage" "MinIO is ready and the lightdash bucket exists"
}

setup_helm_repos() {
    helm repo add lightdash https://lightdash.github.io/helm-charts --force-update >/dev/null
    helm repo add bitnami https://charts.bitnami.com/bitnami --force-update >/dev/null
    helm repo add browserless-chrome https://charts.sagikazarmark.dev --force-update >/dev/null
    helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update >/dev/null
    helm repo update >/dev/null
}

highest_released_version() {
    local version
    version="$(helm search repo lightdash/lightdash --versions -o json | jq -r '.[].version' | sort -V | tail -n 1)"
    if [[ -z "$version" ]]; then
        fail "Chart resolution" "the Lightdash chart repository returned no versions"
    fi
    printf '%s\n' "$version"
}

version_less_than() {
    local version="${1#v}"
    local maximum="${2#v}"
    [[ "$version" != "$maximum" && "$(printf '%s\n%s\n' "$version" "$maximum" | sort -V | head -n 1)" == "$version" ]]
}

highest_released_version_before() {
    local target="$1"
    local version
    local selected=""
    while IFS= read -r version; do
        if version_less_than "$version" "$target"; then
            selected="$version"
        fi
    done < <(helm search repo lightdash/lightdash --versions -o json | jq -r '.[].version' | sort -V)
    if [[ -z "$selected" ]]; then
        fail "Chart resolution" "the Lightdash chart repository returned no version older than $target"
    fi
    printf '%s\n' "$selected"
}

chart_version_for_source() {
    local source="$1"
    chart_metadata "$source" | awk '/^version:/ {gsub(/"/, "", $2); print $2}'
}

resolve_sources() {
    local source_version
    local target_version
    setup_helm_repos
    if [[ "$TO_SOURCE" == "local" ]]; then
        helm dependency build "$LOCAL_CHART" >/dev/null
    fi
    target_version="$(chart_version_for_source "$TO_SOURCE")"
    if [[ "$FROM_EXPLICIT" != "true" ]]; then
        FROM_SOURCE="$(highest_released_version_before "$target_version")"
    elif [[ "$FROM_SOURCE" == "latest" ]]; then
        FROM_SOURCE="$(highest_released_version)"
    fi
    source_version="$(chart_version_for_source "$FROM_SOURCE")"
    if [[ "$INSTALL_ONLY" != "true" && "$DRILL" != "drain" && "$ALLOW_NON_FORWARD" != "true" ]] && ! version_less_than "$source_version" "$target_version"; then
        fail "Chart resolution" "source chart $source_version must be older than target chart $target_version; pass --allow-non-forward to override"
    fi
    record_result "PASS" "Chart resolution" "from=$FROM_SOURCE ($source_version) to=$TO_SOURCE ($target_version)"
}

image_setting_from_values() {
    local file="$1"
    local setting="$2"
    awk -v setting="$setting" '
        /^[^[:space:]]/ { in_image = ($0 ~ /^image:[[:space:]]*$/) }
        in_image && $0 ~ "^[[:space:]]+" setting ":[[:space:]]*" {
            value = $0
            sub("^[[:space:]]+" setting ":[[:space:]]*", "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            gsub(/^['\''\"]|['\''\"]$/, "", value)
            print value
            exit
        }
    ' "$file"
}

chart_metadata() {
    local source="$1"
    if [[ "$source" == "local" ]]; then
        helm show chart "$LOCAL_CHART"
    else
        helm show chart lightdash/lightdash --version "$source"
    fi
}

chart_default_values() {
    local source="$1"
    if [[ "$source" == "local" ]]; then
        helm show values "$LOCAL_CHART"
    else
        helm show values lightdash/lightdash --version "$source"
    fi
}

app_image_for_source() {
    local source="$1"
    local app_version
    local repository
    local tag
    local chart_values_file
    app_version="$(chart_metadata "$source" | awk '$1 == "appVersion:" {gsub(/"/, "", $2); print $2}')"
    chart_values_file="$TEMP_DIR/chart-values-${source//[^a-zA-Z0-9]/_}.yaml"
    chart_default_values "$source" >"$chart_values_file"
    repository="$(image_setting_from_values "$VALUES_FILE" repository)"
    tag="$(image_setting_from_values "$VALUES_FILE" tag)"
    if [[ -z "$repository" ]]; then
        repository="$(image_setting_from_values "$chart_values_file" repository)"
    fi
    if [[ -z "$repository" ]]; then
        repository="lightdash/lightdash"
    fi
    if [[ -z "$tag" ]]; then
        tag="$app_version"
    fi
    if [[ -z "$tag" ]]; then
        fail "Apple Silicon images" "could not resolve the app image tag for chart source $source"
    fi
    printf '%s:%s\n' "$repository" "$tag"
}

image_has_arm64_manifest() {
    local image="$1"
    local manifest_file="$TEMP_DIR/manifest-${image//[^a-zA-Z0-9]/_}.json"
    if ! docker manifest inspect "$image" >"$manifest_file"; then
        fail "Apple Silicon images" "could not inspect the image manifest for $image"
    fi
    jq -e 'any(.manifests[]?; .platform.os == "linux" and .platform.architecture == "arm64")' "$manifest_file" >/dev/null
}

verify_x86_emulation() {
    local binfmt_entries
    binfmt_entries="$(docker exec "$CLUSTER_NAME-control-plane" sh -c 'ls -1 /proc/sys/fs/binfmt_misc 2>/dev/null' || true)"
    if ! printf '%s\n' "$binfmt_entries" | grep -Eq '^(rosetta|qemu-x86_64|x86_64)$'; then
        fail "Apple Silicon emulation" "enable Rosetta for x86/amd64 emulation in Docker Desktop settings"
    fi
    record_result "PASS" "Apple Silicon emulation" "the kind node has an x86_64 binfmt handler"
}

flatten_amd64_image_tag() {
    local image="$1"
    local repository
    local manifest_digest
    local manifest_file="$TEMP_DIR/manifest-${image//[^a-zA-Z0-9]/_}.json"
    repository="${image%:*}"
    manifest_digest="$(jq -r '.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest' "$manifest_file" | head -n 1)"
    if [[ -z "$manifest_digest" ]]; then
        fail "Apple Silicon images" "the image $image has no linux/amd64 manifest"
    fi
    docker pull "$repository@$manifest_digest" >/dev/null
    docker tag "$repository@$manifest_digest" "$image"
}

prepare_apple_silicon_images() {
    local host_arch
    local image
    local from_image
    local to_image
    local images=""
    local missing_images=""
    host_arch="$(uname -m)"
    if [[ "$host_arch" != "arm64" && "$host_arch" != "aarch64" ]]; then
        record_result "SKIP" "Apple Silicon images" "host architecture is $host_arch"
        return
    fi
    if [[ "$SKIP_CLUSTER" == "true" ]]; then
        record_result "SKIP" "Apple Silicon images" "--skip-cluster leaves image loading to the current context"
        return
    fi
    to_image="$(app_image_for_source "$TO_SOURCE")"
    images="$to_image"
    if [[ "$INSTALL_ONLY" != "true" && "$DRILL" != "drain" ]]; then
        from_image="$(app_image_for_source "$FROM_SOURCE")"
        if [[ "$from_image" != "$to_image" ]]; then
            images="$from_image"$'\n'"$to_image"
        fi
    fi
    while IFS= read -r image; do
        if [[ -n "$image" ]] && ! image_has_arm64_manifest "$image"; then
            if [[ -n "$missing_images" ]]; then
                missing_images+=$'\n'
            fi
            missing_images+="$image"
        fi
    done <<<"$images"
    if [[ -z "$missing_images" ]]; then
        record_result "SKIP" "Apple Silicon images" "all required app images publish ARM64 manifests"
        return
    fi
    verify_x86_emulation
    while IFS= read -r image; do
        if [[ -z "$image" ]]; then
            continue
        fi
        docker pull --platform linux/amd64 "$image" >/dev/null
        flatten_amd64_image_tag "$image"
        kind load docker-image "$image" --name "$CLUSTER_NAME" >/dev/null
        record_result "PASS" "Apple Silicon image" "loaded $image as linux/amd64"
    done <<<"$missing_images"
}

write_overlay() {
    OVERLAY_FILE="$TEMP_DIR/drill-values.yaml"
    case "$DRILL" in
        parked-migration | killed-migrator)
            cat >"$OVERLAY_FILE" <<'YAML'
migrationJob:
  enabled: true
YAML
            ;;
        slow-migration)
            cat >"$OVERLAY_FILE" <<'YAML'
lightdashBackend:
  startupProbe:
    failureThreshold: 60
YAML
            ;;
        drain)
            map_drain_nodes
            cat >"$OVERLAY_FILE" <<YAML
nodeSelector:
  rehearsal.lightdash/role: app
postgresql:
  primary:
    nodeSelector:
      rehearsal.lightdash/role: database
YAML
            ;;
        "")
            OVERLAY_FILE=""
            ;;
    esac
}

map_drain_nodes() {
    local workers
    workers="$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null) | .metadata.name' | sort)"
    DRAIN_DB_NODE="$(printf '%s\n' "$workers" | sed -n '1p')"
    DRAIN_APP_NODE="$(printf '%s\n' "$workers" | sed -n '2p')"
    if [[ -z "$DRAIN_DB_NODE" || -z "$DRAIN_APP_NODE" ]]; then
        fail "Drain topology" "the drain drill requires two worker nodes"
    fi
    kubectl label node "$DRAIN_DB_NODE" rehearsal.lightdash/role=database --overwrite >/dev/null
    kubectl label node "$DRAIN_APP_NODE" rehearsal.lightdash/role=app --overwrite >/dev/null
    record_result "PASS" "Drain topology" "database=$DRAIN_DB_NODE application=$DRAIN_APP_NODE"
}

append_values_args() {
    HELM_COMMAND+=(-f "$VALUES_FILE")
    if [[ -n "$OVERLAY_FILE" ]]; then
        HELM_COMMAND+=(-f "$OVERLAY_FILE")
    fi
}

declare -a HELM_COMMAND=()

build_install_command() {
    local source="$1"
    HELM_COMMAND=(helm install "$RELEASE_NAME")
    if [[ "$source" == "local" ]]; then
        HELM_COMMAND+=("$LOCAL_CHART")
    else
        HELM_COMMAND+=(lightdash/lightdash --version "$source")
    fi
    append_values_args
    HELM_COMMAND+=(--wait --timeout 15m)
}

build_upgrade_command() {
    HELM_COMMAND=(helm upgrade "$RELEASE_NAME")
    if [[ "$TO_SOURCE" == "local" ]]; then
        HELM_COMMAND+=("$LOCAL_CHART")
    else
        HELM_COMMAND+=(lightdash/lightdash --version "$TO_SOURCE")
    fi
    append_values_args
    HELM_COMMAND+=(--wait --timeout 15m)
}

install_chart() {
    local source="$FROM_SOURCE"
    if [[ "$INSTALL_ONLY" == "true" || "$DRILL" == "drain" ]]; then
        source="$TO_SOURCE"
    fi
    build_install_command "$source"
    "${HELM_COMMAND[@]}"
    record_result "PASS" "Helm install" "installed chart source $source"
    wait_for_postgres
}

wait_for_postgres() {
    local attempt
    for ((attempt = 1; attempt <= 120; attempt += 1)); do
        if kubectl get pod -n "$NAMESPACE" "$RELEASE_NAME-postgresql-0" >/dev/null 2>&1; then
            if kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$RELEASE_NAME-postgresql-0" --timeout=10m >/dev/null; then
                return
            fi
        fi
        sleep 1
    done
    fail "PostgreSQL readiness" "the bundled database did not become Ready"
}

create_client_pod() {
    kubectl run -n "$NAMESPACE" "$CLIENT_POD" --image=curlimages/curl:8.12.1 --restart=Never --command -- sleep 7200 >/dev/null
    CLIENT_CREATED=true
    kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$CLIENT_POD" --timeout=5m >/dev/null
}

backend_pod_template_hash() {
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=backend -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .metadata.labels["pod-template-hash"] // empty] | unique | first // empty'
}

assert_backend_rollout() {
    local before="$1"
    local after
    after="$(backend_pod_template_hash)"
    if [[ -z "$after" ]]; then
        record_result "FAIL" "Backend rollout" "no Ready backend pod exposes pod-template-hash after the upgrade"
    elif [[ "$after" == "$before" ]]; then
        record_result "FAIL" "Backend rollout" "pod-template-hash remained $before"
    else
        record_result "PASS" "Backend rollout" "pod-template-hash changed from $before to $after"
    fi
}

wait_for_api() {
    local attempt
    for ((attempt = 1; attempt <= 60; attempt += 1)); do
        if kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -fsS --max-time 2 "http://$RELEASE_NAME:8080/api/v1/health" >/dev/null 2>&1; then
            return
        fi
        sleep 2
    done
    fail "API readiness" "the health endpoint did not become ready"
}

HTTP_BODY=""
HTTP_CODE=""

api_post() {
    local path="$1"
    local payload="$2"
    local response
    response="$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -sS --max-time 20 -H 'Content-Type: application/json' -X POST -d "$payload" -w $'\n%{http_code}' "http://$RELEASE_NAME:8080$path")"
    HTTP_CODE="$(printf '%s\n' "$response" | tail -n 1)"
    HTTP_BODY="$(printf '%s\n' "$response" | sed '$d')"
}

seed_rehearsal() {
    local register_payload
    local marker_count
    psql_app "CREATE TABLE IF NOT EXISTS rehearsal_seed (marker text); INSERT INTO rehearsal_seed VALUES ('$RUN_ID');" >/dev/null
    marker_count="$(psql_app "SELECT count(*) FROM rehearsal_seed WHERE marker = '$RUN_ID';")"
    if [[ "$marker_count" != "1" ]]; then
        fail "Database seed" "the rehearsal marker was not inserted"
    fi
    register_payload="$(jq -nc --arg email "$USER_EMAIL" --arg password "$USER_PASSWORD" '{firstName:"Rehearsal",lastName:"User",email:$email,password:$password}')"
    api_post "/api/v1/user" "$register_payload"
    if [[ "$HTTP_CODE" != "200" ]] || ! printf '%s' "$HTTP_BODY" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        fail "API seed" "registration returned HTTP $HTTP_CODE: $HTTP_BODY"
    fi
    record_result "PASS" "Seed" "database marker and first user were created"
}

table_exists() {
    local table="$1"
    [[ "$(psql_app "SELECT to_regclass('public.$table') IS NOT NULL;")" == "t" ]]
}

capture_migration_baseline() {
    MIGRATION_BEFORE="$(psql_app "SELECT COALESCE(max(name), '') FROM knex_migrations;")"
    MIGRATION_COUNT_BEFORE="$(psql_app "SELECT count(*) FROM knex_migrations;")"
    if table_exists migration_run_ledger; then
        LEDGER_EXISTED_BEFORE=true
        LEDGER_COUNT_BEFORE="$(psql_app "SELECT count(*) FROM migration_run_ledger;")"
    else
        LEDGER_EXISTED_BEFORE=false
        LEDGER_COUNT_BEFORE=0
    fi
}

backend_deployment_rollout_config() {
    kubectl get deployment -n "$NAMESPACE" "$RELEASE_NAME-backend" -o json |
        jq -c '{replicas: .spec.replicas, strategy: .spec.strategy, availableReplicas: (.status.availableReplicas // 0), readyReplicas: (.status.readyReplicas // 0), updatedReplicas: (.status.updatedReplicas // 0)}'
}

postgres_pod_uid() {
    kubectl get pod -n "$NAMESPACE" "$RELEASE_NAME-postgresql-0" -o jsonpath='{.metadata.uid}' 2>/dev/null || true
}

start_rollout_observer() {
    ROLLOUT_OBSERVER_FILE="$TEMP_DIR/backend-rollout.tsv"
    ROLLOUT_DEPLOYMENT_BEFORE="$(backend_deployment_rollout_config)"
    POSTGRES_POD_UID_BEFORE="$(postgres_pod_uid)"
    (
        local sample_index=0
        while true; do
            local epoch
            local endpoint_state
            local pod_state
            local postgres_endpoint_state
            local postgres_pod_state
            epoch="$(date +%s)"
            endpoint_state="$(
                kubectl get endpointslices.discovery.k8s.io -n "$NAMESPACE" -l "kubernetes.io/service-name=$RELEASE_NAME" -o json 2>/dev/null |
                    jq -c '{
                        readyAddresses: ([.items[].endpoints[]? | select(.conditions.ready == true) | .addresses[]?] | length),
                        endpoints: ([.items[].endpoints[]? | {
                            addresses: .addresses,
                            ready: (if ((.conditions // {}) | has("ready")) then .conditions.ready else null end),
                            serving: (if ((.conditions // {}) | has("serving")) then .conditions.serving else null end),
                            terminating: (if ((.conditions // {}) | has("terminating")) then .conditions.terminating else null end),
                            pod: (.targetRef.name // null)
                        }] | sort_by(.pod))
                    }' 2>/dev/null || printf '{"error":"endpoint-query-failed"}'
            )"
            pod_state="$(
                kubectl get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=lightdash,app.kubernetes.io/instance=$RELEASE_NAME,app.kubernetes.io/component=backend" -o json 2>/dev/null |
                    jq -c '[.items[] | {
                        name: .metadata.name,
                        hash: (.metadata.labels["pod-template-hash"] // null),
                        phase: (.status.phase // null),
                        ready: (([.status.conditions[]? | select(.type == "Ready")][0].status) // "Unknown"),
                        deleting: (.metadata.deletionTimestamp // null)
                    }] | sort_by(.name)' 2>/dev/null || printf '[{"error":"pod-query-failed"}]'
            )"
            postgres_endpoint_state="$(
                kubectl get endpointslices.discovery.k8s.io -n "$NAMESPACE" -l "kubernetes.io/service-name=$RELEASE_NAME-postgresql" -o json 2>/dev/null |
                    jq -c '{
                        readyAddresses: ([.items[].endpoints[]? | select(.conditions.ready == true) | .addresses[]?] | length),
                        endpoints: ([.items[].endpoints[]? | {
                            addresses: .addresses,
                            ready: (if ((.conditions // {}) | has("ready")) then .conditions.ready else null end),
                            serving: (if ((.conditions // {}) | has("serving")) then .conditions.serving else null end),
                            terminating: (if ((.conditions // {}) | has("terminating")) then .conditions.terminating else null end),
                            pod: (.targetRef.name // null)
                        }] | sort_by(.pod))
                    }' 2>/dev/null || printf '{"error":"postgres-endpoint-query-failed"}'
            )"
            postgres_pod_state="$(
                kubectl get pod -n "$NAMESPACE" "$RELEASE_NAME-postgresql-0" -o json 2>/dev/null |
                    jq -c '{
                        name: .metadata.name,
                        uid: .metadata.uid,
                        ownerUid: (([.metadata.ownerReferences[]? | select(.kind == "StatefulSet")][0].uid) // null),
                        phase: (.status.phase // null),
                        ready: (([.status.conditions[]? | select(.type == "Ready")][0].status) // "Unknown"),
                        deleting: (.metadata.deletionTimestamp // null)
                    }' 2>/dev/null || printf '{"error":"postgres-pod-query-failed"}'
            )"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$epoch" "$sample_index" "$endpoint_state" "$pod_state" "$postgres_endpoint_state" "$postgres_pod_state"
            sample_index=$((sample_index + 1))
            sleep 0.5
        done
    ) >"$ROLLOUT_OBSERVER_FILE" &
    ROLLOUT_OBSERVER_PID=$!
}

stop_rollout_observer() {
    if [[ -z "$ROLLOUT_OBSERVER_PID" ]]; then
        return
    fi
    kill "$ROLLOUT_OBSERVER_PID" >/dev/null 2>&1 || true
    wait "$ROLLOUT_OBSERVER_PID" >/dev/null 2>&1 || true
    ROLLOUT_OBSERVER_PID=""
}

print_rollout_timeline() {
    printf 'Backend Deployment before upgrade: %s\n' "$ROLLOUT_DEPLOYMENT_BEFORE"
    printf 'Backend Deployment after upgrade: %s\n' "$ROLLOUT_DEPLOYMENT_AFTER"
    if [[ ! -s "$ROLLOUT_OBSERVER_FILE" ]]; then
        printf 'Backend rollout timeline: no samples\n'
        return
    fi
    printf 'Backend rollout timeline (state changes from 0.5s samples):\n'
    awk -F '\t' -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" -v assertion="$TRAFFIC_ASSERT_EPOCH" '
        $1 ~ /^[0-9]+$/ && $1 >= start && $1 <= assertion {
            state = $3 FS $4 FS $5 FS $6
            if (state != previous) {
                phase = $1 <= end ? "helm-upgrade" : "post-upgrade"
                printf "%s sample=%s phase=%s backendEndpoints=%s backendPods=%s postgresEndpoints=%s postgresPod=%s\n", $1, $2, phase, $3, $4, $5, $6
                previous = state
            }
        }
    ' "$ROLLOUT_OBSERVER_FILE"
}

assert_postgres_pod_uid_stable() {
    POSTGRES_POD_UID_AFTER="$(postgres_pod_uid)"
    if [[ -z "$POSTGRES_POD_UID_BEFORE" ]]; then
        record_result "FAIL" "PostgreSQL pod UID" "the pod UID was unavailable before the upgrade"
    elif [[ -z "$POSTGRES_POD_UID_AFTER" ]]; then
        record_result "FAIL" "PostgreSQL pod UID" "the pod UID was unavailable after the upgrade"
    elif [[ "$POSTGRES_POD_UID_BEFORE" == "$POSTGRES_POD_UID_AFTER" ]]; then
        record_result "PASS" "PostgreSQL pod UID" "the pod UID remained $POSTGRES_POD_UID_AFTER"
    else
        record_result "FAIL" "PostgreSQL pod UID" "the pod UID changed from $POSTGRES_POD_UID_BEFORE to $POSTGRES_POD_UID_AFTER"
    fi
}

start_traffic_monitor() {
    local initial_samples
    local observer_samples
    local monitor_command
    # The browser route represents user traffic through the Service without the database-backed diagnostics run by /api/v1/health.
    monitor_command="while true; do epoch=\$(date +%s); output=\$(curl -sS -o /dev/null -w \"%{http_code} %{time_total}\" --max-time 10 http://lightdash:8080/ 2>/dev/null); curl_exit=\$?; set -- \$output; printf \"%s %s %s %s\\n\" \"\$epoch\" \"\${1:-000}\" \"\$curl_exit\" \"\${2:-0}\"; sleep 0.5; done"
    kubectl run -n "$NAMESPACE" "$TRAFFIC_POD" --image=curlimages/curl:8.12.1 --restart=Never --command -- sh -c "$monitor_command" >/dev/null
    TRAFFIC_CREATED=true
    kubectl wait -n "$NAMESPACE" --for=condition=Ready "pod/$TRAFFIC_POD" --timeout=5m >/dev/null
    start_rollout_observer
    sleep 2
    initial_samples="$(kubectl logs -n "$NAMESPACE" "$TRAFFIC_POD" | awk '$1 ~ /^[0-9]+$/ {count += 1} END {print count + 0}')"
    observer_samples="$(wc -l <"$ROLLOUT_OBSERVER_FILE" | tr -d '[:space:]')"
    if ((initial_samples < 2)); then
        fail "Traffic monitor setup" "the monitor produced only $initial_samples samples before the upgrade"
    fi
    if ((observer_samples < 2)) || ! kill -0 "$ROLLOUT_OBSERVER_PID" >/dev/null 2>&1; then
        fail "Rollout observer setup" "the observer produced $observer_samples samples before the upgrade"
    fi
    record_result "PASS" "Traffic monitor setup" "the monitor produced $initial_samples samples before the upgrade"
    record_result "PASS" "Rollout observer setup" "the observer produced $observer_samples samples before the upgrade"
}

assert_helm_deployed() {
    local status
    status="$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r '.info.status')"
    if [[ "$status" == "deployed" ]]; then
        record_result "PASS" "Helm release" "status is deployed"
    else
        record_result "FAIL" "Helm release" "status is $status"
    fi
}

assert_migrations() {
    local migration_after
    local lock_count
    migration_after="$(psql_app "SELECT COALESCE(max(name), '') FROM knex_migrations;")"
    lock_count="$(psql_app "SELECT count(*) FROM knex_migrations_lock WHERE is_locked = 1;")"
    if [[ "$INSTALL_ONLY" == "true" || "$DRILL" == "drain" || "$migration_after" == "$MIGRATION_BEFORE" || "$migration_after" > "$MIGRATION_BEFORE" ]]; then
        record_result "PASS" "Migration order" "newest migration is ${migration_after:-none}"
    else
        record_result "FAIL" "Migration order" "migration moved backwards from $MIGRATION_BEFORE to $migration_after"
    fi
    if [[ "$lock_count" == "0" ]]; then
        record_result "PASS" "Migration lock" "no knex migration lock is held"
    else
        record_result "FAIL" "Migration lock" "$lock_count migration lock rows remain held"
    fi
}

assert_ledger() {
    local migration_count_after
    local ledger_count_after
    local newest_outcome
    if ! table_exists migration_run_ledger; then
        record_result "FAIL" "Migration ledger" "migration_run_ledger does not exist"
        return
    fi
    migration_count_after="$(psql_app "SELECT count(*) FROM knex_migrations;")"
    ledger_count_after="$(psql_app "SELECT count(*) FROM migration_run_ledger;")"
    if ((ledger_count_after > 0)); then
        newest_outcome="$(psql_app "SELECT outcome FROM migration_run_ledger ORDER BY started_at DESC LIMIT 1;")"
    else
        newest_outcome=""
    fi
    if [[ "$LEDGER_EXISTED_BEFORE" == "true" ]]; then
        if ((migration_count_after > MIGRATION_COUNT_BEFORE)) && ((ledger_count_after > LEDGER_COUNT_BEFORE)) && [[ "$newest_outcome" == "succeeded" ]]; then
            record_result "PASS" "Migration ledger" "new migrations produced a new succeeded run"
        elif ((migration_count_after == MIGRATION_COUNT_BEFORE)) && [[ "$newest_outcome" == "succeeded" ]]; then
            record_result "PASS" "Migration ledger" "no pending migrations; no new ledger row expected"
        else
            record_result "FAIL" "Migration ledger" "migrations before=$MIGRATION_COUNT_BEFORE after=$migration_count_after; ledger rows before=$LEDGER_COUNT_BEFORE after=$ledger_count_after; newest outcome=${newest_outcome:-none}"
        fi
    elif ((ledger_count_after > 0)) && [[ "$newest_outcome" == "succeeded" ]]; then
        record_result "PASS" "Migration ledger" "the ledger appeared with a succeeded run"
    elif ((ledger_count_after == 0 && migration_count_after == MIGRATION_COUNT_BEFORE)); then
        record_result "PASS" "Migration ledger" "the ledger appeared empty because no migrations were pending"
    else
        record_result "FAIL" "Migration ledger" "the ledger appeared without a succeeded run"
    fi
}

version_at_least() {
    local version="${1#v}"
    local minimum="$2"
    [[ "$(printf '%s\n%s\n' "$minimum" "$version" | sort -V | head -n 1)" == "$minimum" ]]
}

target_app_version() {
    if [[ "$TO_SOURCE" == "local" ]]; then
        helm show chart "$LOCAL_CHART" | awk '$1 == "appVersion:" {gsub(/"/, "", $2); print $2}'
    else
        helm show chart lightdash/lightdash --version "$TO_SOURCE" | awk '$1 == "appVersion:" {gsub(/"/, "", $2); print $2}'
    fi
}

assert_readyz() {
    local app_version
    app_version="$(target_app_version)"
    if [[ "$TO_SOURCE" != "local" ]] && ! version_at_least "$app_version" "1.160.0"; then
        record_result "SKIP" "readyz" "target app version $app_version predates readyz"
        return
    fi
    local response
    local code
    local body
    response="$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -sS --max-time 10 -w $'\n%{http_code}' "http://$RELEASE_NAME:8080/api/v1/readyz")"
    code="$(printf '%s\n' "$response" | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    if [[ "$code" == "200" ]] && printf '%s' "$body" | jq -e '.status == "ready"' >/dev/null 2>&1; then
        record_result "PASS" "readyz" "target reports ready"
    else
        record_result "FAIL" "readyz" "HTTP $code: $body"
    fi
}

traffic_counts() {
    local logs
    logs="$(kubectl logs -n "$NAMESPACE" "$TRAFFIC_POD")"
    TRAFFIC_SAMPLE_COUNT="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end {count += 1} END {print count + 0}')"
    TRAFFIC_REFUSED_COUNT="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end && $3 == "7" {count += 1} END {print count + 0}')"
    TRAFFIC_TIMEOUT_COUNT="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end && $3 == "28" {count += 1} END {print count + 0}')"
    TRAFFIC_5XX_COUNT="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end && $3 == "0" && $2 ~ /^5[0-9][0-9]$/ {count += 1} END {print count + 0}')"
    TRAFFIC_OTHER_CURL_COUNT="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end && $3 != "0" && $3 != "7" && $3 != "28" {count += 1} END {print count + 0}')"
    TRAFFIC_OTHER_HTTP_COUNT="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end && $3 == "0" && $2 != "200" && $2 !~ /^5[0-9][0-9]$/ {count += 1} END {print count + 0}')"
    TRAFFIC_FAILURE_COUNT=$((TRAFFIC_REFUSED_COUNT + TRAFFIC_5XX_COUNT + TRAFFIC_OTHER_CURL_COUNT + TRAFFIC_OTHER_HTTP_COUNT))
    TRAFFIC_FIRST_EPOCH="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end {print $1; exit}')"
    TRAFFIC_LAST_EPOCH="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= end {last = $1} END {print last}')"
    TRAFFIC_ANOMALY_TIMELINE="$(printf '%s\n' "$logs" | awk -v start="$UPGRADE_START_EPOCH" -v end="$UPGRADE_END_EPOCH" -v assertion="$TRAFFIC_ASSERT_EPOCH" '$1 ~ /^[0-9]+$/ && $1 >= start && $1 <= assertion && ($2 != "200" || $3 != "0") {phase = $1 <= end ? "helm-upgrade" : "post-upgrade"; printf "%s phase=%s http=%s curl_exit=%s time_total=%ss\n", $1, phase, $2, $3, $4}')"
}

TRAFFIC_SAMPLE_COUNT=0
TRAFFIC_REFUSED_COUNT=0
TRAFFIC_TIMEOUT_COUNT=0
TRAFFIC_5XX_COUNT=0
TRAFFIC_OTHER_CURL_COUNT=0
TRAFFIC_OTHER_HTTP_COUNT=0
TRAFFIC_FAILURE_COUNT=0
TRAFFIC_FIRST_EPOCH=""
TRAFFIC_LAST_EPOCH=""
TRAFFIC_ASSERT_EPOCH=0
TRAFFIC_ANOMALY_TIMELINE=""

assert_traffic() {
    local monitor_phase
    local window_seconds=$((UPGRADE_END_EPOCH - UPGRADE_START_EPOCH))
    local bucket_details
    TRAFFIC_ASSERT_EPOCH="$(date +%s)"
    stop_rollout_observer
    ROLLOUT_DEPLOYMENT_AFTER="$(backend_deployment_rollout_config)"
    monitor_phase="$(kubectl get pod -n "$NAMESPACE" "$TRAFFIC_POD" -o jsonpath='{.status.phase}')"
    traffic_counts
    bucket_details="refused=$TRAFFIC_REFUSED_COUNT timeout=$TRAFFIC_TIMEOUT_COUNT http_5xx=$TRAFFIC_5XX_COUNT other_curl=$TRAFFIC_OTHER_CURL_COUNT other_http=$TRAFFIC_OTHER_HTTP_COUNT"
    printf 'Traffic phase markers: upgrade_start=%s helm_wait_end=%s assertion=%s samples=%s..%s\n' "$UPGRADE_START_EPOCH" "$UPGRADE_END_EPOCH" "$TRAFFIC_ASSERT_EPOCH" "${TRAFFIC_FIRST_EPOCH:-none}" "${TRAFFIC_LAST_EPOCH:-none}"
    if [[ -n "$TRAFFIC_ANOMALY_TIMELINE" ]]; then
        printf 'Traffic anomaly timeline:\n%s\n' "$TRAFFIC_ANOMALY_TIMELINE"
    else
        printf 'Traffic anomaly timeline: none\n'
    fi
    print_rollout_timeline
    assert_postgres_pod_uid_stable
    if [[ "$monitor_phase" != "Running" ]]; then
        record_result "FAIL" "Traffic monitor coverage" "the monitor phase is $monitor_phase after the ${window_seconds}s upgrade window"
    elif ((TRAFFIC_SAMPLE_COUNT == 0)); then
        record_result "FAIL" "Traffic" "the monitor captured no upgrade samples"
    elif ((TRAFFIC_FIRST_EPOCH > UPGRADE_START_EPOCH + 1 || TRAFFIC_LAST_EPOCH < UPGRADE_END_EPOCH - 2)); then
        record_result "FAIL" "Traffic monitor coverage" "samples span $TRAFFIC_FIRST_EPOCH to $TRAFFIC_LAST_EPOCH for the $UPGRADE_START_EPOCH to $UPGRADE_END_EPOCH upgrade window"
    elif ((TRAFFIC_FAILURE_COUNT <= ALLOWED_DROPS)); then
        record_result "PASS" "Traffic" "$TRAFFIC_FAILURE_COUNT of $TRAFFIC_SAMPLE_COUNT requests failed in ${window_seconds}s ($bucket_details); allowance is $ALLOWED_DROPS"
    else
        record_result "FAIL" "Traffic" "$TRAFFIC_FAILURE_COUNT of $TRAFFIC_SAMPLE_COUNT requests failed in ${window_seconds}s ($bucket_details); allowance is $ALLOWED_DROPS"
    fi
}

assert_seed_survived() {
    local marker_count
    local login_payload
    marker_count="$(psql_app "SELECT count(*) FROM rehearsal_seed WHERE marker = '$RUN_ID';")"
    login_payload="$(jq -nc --arg email "$USER_EMAIL" --arg password "$USER_PASSWORD" '{email:$email,password:$password}')"
    api_post "/api/v1/login" "$login_payload"
    if [[ "$marker_count" == "1" ]]; then
        record_result "PASS" "Database seed survived" "marker $RUN_ID remains"
    else
        record_result "FAIL" "Database seed survived" "expected one marker and found $marker_count"
    fi
    if [[ "$HTTP_CODE" == "200" ]] && printf '%s' "$HTTP_BODY" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        record_result "PASS" "User seed survived" "$USER_EMAIL can log in"
    else
        record_result "FAIL" "User seed survived" "login returned HTTP $HTTP_CODE: $HTTP_BODY"
    fi
}

assert_successful_rehearsal() {
    assert_helm_deployed
    assert_migrations
    assert_ledger
    assert_readyz
    if [[ "$INSTALL_ONLY" != "true" ]]; then
        assert_traffic
    fi
    assert_seed_survived
    if has_failure; then
        exit 1
    fi
}

install_exception_trigger() {
    psql_superuser "CREATE TABLE IF NOT EXISTS rehearsal_ddl_trigger_state (fired_count integer NOT NULL DEFAULT 0); TRUNCATE rehearsal_ddl_trigger_state; INSERT INTO rehearsal_ddl_trigger_state VALUES (0); CREATE OR REPLACE FUNCTION rehearsal_ddl_guard() RETURNS event_trigger LANGUAGE plpgsql AS \$\$ BEGIN IF session_user <> 'postgres' THEN RAISE EXCEPTION 'rehearsal migration failure'; END IF; END; \$\$; DROP EVENT TRIGGER IF EXISTS rehearsal_ddl_guard; CREATE EVENT TRIGGER rehearsal_ddl_guard ON ddl_command_start EXECUTE FUNCTION rehearsal_ddl_guard();" >/dev/null
    DDL_TRIGGER_INSTALLED=true
}

install_sleep_trigger() {
    local seconds="$1"
    psql_superuser "CREATE TABLE IF NOT EXISTS rehearsal_ddl_trigger_state (fired_count integer NOT NULL DEFAULT 0); TRUNCATE rehearsal_ddl_trigger_state; INSERT INTO rehearsal_ddl_trigger_state VALUES (0); CREATE OR REPLACE FUNCTION rehearsal_ddl_guard() RETURNS event_trigger LANGUAGE plpgsql AS \$\$ DECLARE claimed integer; BEGIN IF session_user <> 'postgres' THEN UPDATE rehearsal_ddl_trigger_state SET fired_count = fired_count + 1 WHERE fired_count = 0 RETURNING fired_count INTO claimed; IF claimed = 1 THEN PERFORM pg_sleep($seconds); END IF; END IF; END; \$\$; DROP EVENT TRIGGER IF EXISTS rehearsal_ddl_guard; CREATE EVENT TRIGGER rehearsal_ddl_guard ON ddl_command_start EXECUTE FUNCTION rehearsal_ddl_guard();" >/dev/null
    DDL_TRIGGER_INSTALLED=true
}

upgrade_chart() {
    build_upgrade_command
    UPGRADE_START_EPOCH="$(date +%s)"
    if "${HELM_COMMAND[@]}"; then
        UPGRADE_END_EPOCH="$(date +%s)"
        record_result "PASS" "Helm upgrade command" "helm upgrade exited 0"
    else
        UPGRADE_END_EPOCH="$(date +%s)"
        fail "Helm upgrade command" "helm upgrade exited non-zero"
    fi
    wait_for_postgres
    sleep 1
}

run_happy_path() {
    local backend_hash_before
    CURRENT_STEP="Helm install"
    install_chart
    CURRENT_STEP="API client setup"
    create_client_pod
    wait_for_api
    CURRENT_STEP="rehearsal seed"
    seed_rehearsal
    if [[ "$INSTALL_ONLY" == "true" ]]; then
        MIGRATION_BEFORE=""
        MIGRATION_COUNT_BEFORE=0
        LEDGER_EXISTED_BEFORE=false
        LEDGER_COUNT_BEFORE=0
        assert_successful_rehearsal
        return
    fi
    capture_migration_baseline
    backend_hash_before="$(backend_pod_template_hash)"
    if [[ -z "$backend_hash_before" ]]; then
        fail "Backend rollout" "no Ready backend pod exposes pod-template-hash before the upgrade"
    fi
    CURRENT_STEP="traffic monitor setup"
    start_traffic_monitor
    CURRENT_STEP="Helm upgrade"
    upgrade_chart
    CURRENT_STEP="post-upgrade assertions"
    assert_backend_rollout "$backend_hash_before"
    assert_successful_rehearsal
}

assert_parked_warning() {
    local response
    local code
    local body
    if ! response="$(kubectl exec -n "$NAMESPACE" "$CLIENT_POD" -- curl -sS --max-time 10 -w $'\n%{http_code}' "http://$RELEASE_NAME:8080/api/v1/readyz")"; then
        record_result "FAIL" "Parked warning" "readyz request failed"
        return
    fi
    code="$(printf '%s\n' "$response" | tail -n 1)"
    body="$(printf '%s\n' "$response" | sed '$d')"
    if [[ "$code" == "200" ]] && printf '%s' "$body" | jq -e '.status == "ready" and any(.warnings[]?; . == "migration_parked")' >/dev/null 2>&1; then
        record_result "PASS" "Parked warning" "readyz reports migration_parked"
    else
        record_result "FAIL" "Parked warning" "readyz returned HTTP $code without migration_parked: $body"
    fi
}

run_parked_migration_drill() {
    local upgrade_status
    install_chart
    create_client_pod
    wait_for_api
    seed_rehearsal
    capture_migration_baseline
    start_traffic_monitor
    install_exception_trigger
    build_upgrade_command
    UPGRADE_START_EPOCH="$(date +%s)"
    set +e
    "${HELM_COMMAND[@]}"
    upgrade_status=$?
    set -e
    UPGRADE_END_EPOCH="$(date +%s)"
    wait_for_postgres
    sleep 1
    if ((upgrade_status == 0)); then
        record_result "FAIL" "Parked upgrade" "helm upgrade unexpectedly succeeded"
    else
        record_result "PASS" "Parked upgrade" "the migration hook blocked the upgrade"
    fi
    local newest_outcome=""
    local parked_at=""
    local ledger_count_after=0
    if table_exists migration_run_ledger; then
        ledger_count_after="$(psql_app "SELECT count(*) FROM migration_run_ledger;")"
        newest_outcome="$(psql_app "SELECT outcome FROM migration_run_ledger ORDER BY started_at DESC LIMIT 1;")"
    fi
    if ((ledger_count_after <= LEDGER_COUNT_BEFORE)); then
        record_result "FAIL" "Parked migration" "no pending migrations between from and to; pick an older --from"
    elif [[ "$newest_outcome" == "parked" ]]; then
        record_result "PASS" "Parked migration" "the newest ledger outcome is parked"
    else
        record_result "FAIL" "Parked migration" "the newest ledger outcome is ${newest_outcome:-none}"
    fi
    if table_exists migration_lease; then
        parked_at="$(psql_app "SELECT COALESCE(parked_at::text, '') FROM migration_lease WHERE lease_key = 'global';")"
    fi
    if [[ -n "$parked_at" ]]; then
        record_result "PASS" "Parked lease" "parked_at is $parked_at"
    else
        record_result "FAIL" "Parked lease" "migration_lease.parked_at is null"
    fi
    assert_parked_warning
    local helm_state
    helm_state="$(helm status "$RELEASE_NAME" -n "$NAMESPACE" -o json | jq -r '.info.status')"
    if [[ "$helm_state" != "deployed" ]]; then
        record_result "PASS" "Release rollback boundary" "release state is $helm_state"
    else
        record_result "FAIL" "Release rollback boundary" "the failed hook left the release deployed"
    fi
    assert_traffic
    api_post "/api/v1/login" "$(jq -nc --arg email "$USER_EMAIL" --arg password "$USER_PASSWORD" '{email:$email,password:$password}')"
    if [[ "$HTTP_CODE" == "200" ]]; then
        record_result "PASS" "Old backend availability" "the original backend still serves logins"
    else
        record_result "FAIL" "Old backend availability" "login returned HTTP $HTTP_CODE"
    fi
    remove_ddl_trigger
    if has_failure; then
        exit 1
    fi
}

wait_for_running_migration_pod() {
    local excluded="${1:-}"
    local attempt
    local pod
    for ((attempt = 1; attempt <= 300; attempt += 1)); do
        pod="$(kubectl get pods -n "$NAMESPACE" -l job-name="$RELEASE_NAME-migrate" -o json 2>/dev/null | jq -r --arg excluded "$excluded" '.items[] | select(.metadata.name != $excluded and .status.phase == "Running") | .metadata.name' | head -n 1)"
        if [[ -n "$pod" ]]; then
            printf '%s\n' "$pod"
            return 0
        fi
        sleep 1
    done
    return 1
}

run_killed_migrator_drill() {
    local killed_pod
    local replacement_pod
    local upgrade_pid
    local upgrade_status
    local kill_epoch
    local finish_epoch
    local recovery_seconds
    local ledger_count_after
    local newest_outcome
    local newest_attempt
    install_chart
    create_client_pod
    wait_for_api
    seed_rehearsal
    capture_migration_baseline
    start_traffic_monitor
    install_sleep_trigger 180
    build_upgrade_command
    UPGRADE_START_EPOCH="$(date +%s)"
    "${HELM_COMMAND[@]}" >"$TEMP_DIR/killed-upgrade.log" 2>&1 &
    upgrade_pid=$!
    if ! killed_pod="$(wait_for_running_migration_pod)"; then
        kill "$upgrade_pid" >/dev/null 2>&1 || true
        wait "$upgrade_pid" >/dev/null 2>&1 || true
        fail "Killed migrator" "no pending migrations between from and to; pick an older --from"
    fi
    kill_epoch="$(date +%s)"
    kubectl delete pod -n "$NAMESPACE" "$killed_pod" --wait=true >/dev/null
    if ! replacement_pod="$(wait_for_running_migration_pod "$killed_pod")"; then
        kill "$upgrade_pid" >/dev/null 2>&1 || true
        wait "$upgrade_pid" >/dev/null 2>&1 || true
        fail "Killed migrator" "the Job did not start a replacement pod"
    fi
    remove_ddl_trigger
    set +e
    wait "$upgrade_pid"
    upgrade_status=$?
    set -e
    UPGRADE_END_EPOCH="$(date +%s)"
    wait_for_postgres
    finish_epoch="$(date +%s)"
    recovery_seconds=$((finish_epoch - kill_epoch))
    if ((upgrade_status == 0)); then
        record_result "PASS" "Killed migrator upgrade" "replacement $replacement_pod completed the upgrade"
    else
        record_result "FAIL" "Killed migrator upgrade" "helm upgrade exited $upgrade_status: $(tail -n 5 "$TEMP_DIR/killed-upgrade.log" | tr '\n' ' ')"
    fi
    if ((recovery_seconds <= 90)); then
        record_result "PASS" "Lease takeover delay" "kill-to-completion recovery took ${recovery_seconds}s"
    else
        record_result "FAIL" "Lease takeover delay" "kill-to-completion recovery took ${recovery_seconds}s"
    fi
    ledger_count_after="$(psql_app "SELECT count(*) FROM migration_run_ledger;")"
    newest_outcome="$(psql_app "SELECT outcome FROM migration_run_ledger ORDER BY started_at DESC LIMIT 1;")"
    newest_attempt="$(psql_app "SELECT attempt FROM migration_run_ledger ORDER BY started_at DESC LIMIT 1;")"
    if [[ "$newest_outcome" == "succeeded" ]] && { ((newest_attempt >= 2)) || ((ledger_count_after >= LEDGER_COUNT_BEFORE + 2)); }; then
        record_result "PASS" "Migrator retry ledger" "outcome=$newest_outcome attempt=$newest_attempt rows=$ledger_count_after"
    else
        record_result "FAIL" "Migrator retry ledger" "outcome=$newest_outcome attempt=$newest_attempt rows=$ledger_count_after"
    fi
    assert_successful_rehearsal
}

run_slow_migration_drill() {
    local old_pod
    local new_pod
    local restarts
    local fired_count
    install_chart
    create_client_pod
    wait_for_api
    seed_rehearsal
    capture_migration_baseline
    start_traffic_monitor
    old_pod="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=backend -o json | jq -r '.items[0].metadata.name')"
    install_sleep_trigger 240
    upgrade_chart
    fired_count="$(psql_superuser "SELECT fired_count FROM rehearsal_ddl_trigger_state;")"
    remove_ddl_trigger
    if [[ "$fired_count" == "1" ]]; then
        record_result "PASS" "Slow migration injection" "a pending migration slept for 240s"
    else
        record_result "FAIL" "Slow migration injection" "no pending migrations between from and to; pick an older --from"
    fi
    new_pod="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=backend -o json | jq -r --arg old "$old_pod" '.items[] | select(.metadata.name != $old) | .metadata.name' | head -n 1)"
    if [[ -z "$new_pod" ]]; then
        new_pod="$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=backend -o json | jq -r '.items[0].metadata.name')"
    fi
    restarts="$(kubectl get pod -n "$NAMESPACE" "$new_pod" -o json | jq '[.status.containerStatuses[]?.restartCount] | add // 0')"
    if [[ "$restarts" == "0" ]]; then
        record_result "PASS" "Startup probe budget" "$new_pod has zero restarts"
    else
        record_result "FAIL" "Startup probe budget" "$new_pod restarted $restarts times"
    fi
    assert_successful_rehearsal
}

run_drain_drill() {
    local drain_status
    install_chart
    create_client_pod
    wait_for_api
    seed_rehearsal
    set +e
    kubectl drain "$DRAIN_APP_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=180s
    drain_status=$?
    set -e
    if ((drain_status == 0)); then
        record_result "PASS" "Node drain" "$DRAIN_APP_NODE drained within 180s"
    else
        record_result "FAIL" "Node drain" "$DRAIN_APP_NODE did not drain; the current minAvailable: 1 PDB blocks this on main"
    fi
    kubectl uncordon "$DRAIN_APP_NODE" >/dev/null
    if kubectl rollout status -n "$NAMESPACE" deployment/lightdash-backend --timeout=10m >/dev/null; then
        record_result "PASS" "Backend recovery" "the backend returned to Ready after uncordon"
    else
        record_result "FAIL" "Backend recovery" "the backend did not return to Ready"
    fi
    assert_seed_survived
    if has_failure; then
        exit 1
    fi
}

main() {
    parse_args "$@"
    validate_args
    RUN_ID="$(date +%s)-$$"
    USER_EMAIL="rehearsal-$RUN_ID@example.com"
    CLIENT_POD="rehearsal-client-$$"
    TRAFFIC_POD="rehearsal-traffic-$$"
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lightdash-rehearsal.XXXXXX")"
    CURRENT_STEP="preflight"
    preflight
    CURRENT_STEP="kind cluster creation"
    create_cluster
    CURRENT_STEP="MinIO provisioning"
    deploy_minio
    CURRENT_STEP="chart resolution"
    resolve_sources
    CURRENT_STEP="drill overlay preparation"
    write_overlay
    CURRENT_STEP="Apple Silicon image preparation"
    prepare_apple_silicon_images
    CURRENT_STEP="rehearsal flow"
    case "$DRILL" in
        parked-migration)
            CURRENT_STEP="parked-migration drill"
            run_parked_migration_drill
            ;;
        killed-migrator)
            CURRENT_STEP="killed-migrator drill"
            run_killed_migrator_drill
            ;;
        slow-migration)
            CURRENT_STEP="slow-migration drill"
            run_slow_migration_drill
            ;;
        drain)
            CURRENT_STEP="drain drill"
            run_drain_drill
            ;;
        "")
            run_happy_path
            ;;
    esac
}

main "$@"
