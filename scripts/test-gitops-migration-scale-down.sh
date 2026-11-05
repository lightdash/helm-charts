#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
argo_namespace=argocd
app_namespace=gitops-migration-smoke
argo_version=v3.3.19
context="$(kubectl config current-context)"

if [[ "$context" != kind-* ]]; then
    printf 'This smoke test requires a disposable kind context, got %s\n' "$context" >&2
    exit 1
fi

temp_dir="$(mktemp -d)"

cleanup() {
    local status=$?
    if [[ "$status" != 0 ]]; then
        kubectl -n "$argo_namespace" get application gitops -o yaml || true
        kubectl -n "$app_namespace" get pods,deployments,hpa || true
        kubectl -n "$app_namespace" logs job/gitops-lightdash-migrate --all-containers=true --prefix=true || true
        kubectl -n "$app_namespace" get events --sort-by=.lastTimestamp || true
        kubectl -n "$argo_namespace" logs pod/fixture-git || true
        kubectl -n "$argo_namespace" logs deployment/argocd-repo-server --tail=100 || true
        kubectl -n "$argo_namespace" logs statefulset/argocd-application-controller --tail=100 || true
    fi
    kubectl delete namespace "$app_namespace" "$argo_namespace" --ignore-not-found --wait=false || true
    rm -rf "$temp_dir"
}
trap cleanup EXIT

for namespace in "$argo_namespace" "$app_namespace"; do
    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        printf 'Refusing to reuse existing namespace %s\n' "$namespace" >&2
        trap - EXIT
        rm -rf "$temp_dir"
        exit 1
    fi
done

helm repo add migration-smoke-bitnami https://charts.bitnami.com/bitnami
helm repo add migration-smoke-browserless https://charts.sagikazarmark.dev
helm repo add migration-smoke-nats https://nats-io.github.io/k8s/helm/charts/
helm dependency build "$repo_dir/charts/lightdash"
helm template gitops "$repo_dir/charts/lightdash" \
    --namespace "$app_namespace" \
    --set postgresql.enabled=false \
    --set browserless-chrome.enabled=false \
    --set nats.enabled=false \
    --set s3.endpoint=http://object-store \
    --set s3.bucket=test \
    --set s3.region=local \
    --set upgrade.mode=Recreate \
    --set migrationJob.enabled=true \
    --set migrationJob.scaleDownWorkloads.force=true \
    --set migrationJob.ttlSecondsAfterFinished=600 \
    --set image.repository=node \
    --set image.tag=22-alpine \
    --set autoscaling.enabled=true \
    --set autoscaling.minReplicas=2 \
    --set autoscaling.maxReplicas=2 \
    --set scheduler.enabled=true \
    --set appBuildWorker.enabled=true \
    --set warehouseNatsWorker.enabled=true \
    --set preAggregateNatsWorker.enabled=true > "$temp_dir/rendered.yaml"

mkdir "$temp_dir/fixtures"
python3 "$repo_dir/scripts/test-gitops-migration-scale-down-fixtures.py" \
    "$temp_dir/rendered.yaml" "$temp_dir/fixtures/manifests.yaml" "$temp_dir/sentinel.yaml"
git -C "$temp_dir/fixtures" init --initial-branch=main --quiet
git -C "$temp_dir/fixtures" add manifests.yaml
git -C "$temp_dir/fixtures" -c user.name=Smoke -c user.email=smoke@example.invalid commit --quiet -m fixtures
git clone --bare --quiet "$temp_dir/fixtures" "$temp_dir/repository.git"
tar -czf "$temp_dir/repository.tar.gz" -C "$temp_dir" repository.git

kubectl create namespace "$argo_namespace"
kubectl create namespace "$app_namespace"
kubectl -n "$argo_namespace" apply --server-side --force-conflicts \
    -f "https://raw.githubusercontent.com/argoproj/argo-cd/$argo_version/manifests/core-install.yaml"
kubectl -n "$argo_namespace" create configmap fixture-repository --from-file="$temp_dir/repository.tar.gz"
kubectl -n "$argo_namespace" apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: fixture-git
  labels:
    app: fixture-git
spec:
  containers:
    - name: git
      image: quay.io/argoproj/argocd:$argo_version
      command:
        - sh
        - -ec
        - |
          mkdir /tmp/repo
          tar -xzf /source/repository.tar.gz -C /tmp/repo
          exec git daemon --reuseaddr --verbose --base-path=/tmp/repo --export-all --listen=0.0.0.0 --port=9418
      ports:
        - containerPort: 9418
      readinessProbe:
        exec:
          command:
            - git
            - ls-remote
            - git://127.0.0.1:9418/repository.git
            - refs/heads/main
      volumeMounts:
        - name: source
          mountPath: /source
  volumes:
    - name: source
      configMap:
        name: fixture-repository
---
apiVersion: v1
kind: Service
metadata:
  name: fixture-git
spec:
  selector:
    app: fixture-git
  ports:
    - port: 9418
      targetPort: 9418
YAML
kubectl -n "$argo_namespace" rollout status deployment/argocd-repo-server --timeout=300s
kubectl -n "$argo_namespace" rollout status deployment/argocd-redis --timeout=300s
kubectl -n "$argo_namespace" rollout status statefulset/argocd-application-controller --timeout=300s
kubectl -n "$argo_namespace" wait --for=condition=Ready pod/fixture-git --timeout=120s
kubectl -n "$argo_namespace" exec deployment/argocd-repo-server -- \
    git ls-remote "git://fixture-git.$argo_namespace.svc.cluster.local:9418/repository.git" refs/heads/main
kubectl -n "$app_namespace" apply -f "$temp_dir/sentinel.yaml"
kubectl -n "$app_namespace" rollout status deployment/unrelated-backend --timeout=120s
sentinel_uid="$(kubectl -n "$app_namespace" get pods -l app.kubernetes.io/instance=unrelated -o jsonpath='{.items[0].metadata.uid}')"

kubectl -n "$argo_namespace" apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: migration-smoke
spec:
  sourceRepos:
    - git://fixture-git.$argo_namespace.svc.cluster.local:9418/repository.git
  destinations:
    - namespace: $app_namespace
      server: https://kubernetes.default.svc
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gitops
spec:
  project: migration-smoke
  source:
    repoURL: git://fixture-git.$argo_namespace.svc.cluster.local:9418/repository.git
    targetRevision: main
    path: .
    directory: {}
  destination:
    namespace: $app_namespace
    server: https://kubernetes.default.svc
YAML

previous_job_uid=""
for round in 1 2 3; do
    previous_start="$(kubectl -n "$argo_namespace" get application gitops -o jsonpath='{.status.operationState.startedAt}')"
    kubectl -n "$argo_namespace" patch application gitops --type=merge \
        -p '{"operation":{"sync":{"prune":true,"syncStrategy":{"hook":{}}}}}'
    succeeded=false
    for attempt in {1..150}; do
        state="$(kubectl -n "$argo_namespace" get application gitops -o json)"
        started="$(jq -r '.status.operationState.startedAt // ""' <<< "$state")"
        phase="$(jq -r '.status.operationState.phase // ""' <<< "$state")"
        if [[ -n "$started" && "$started" != "$previous_start" ]]; then
            if [[ "$phase" == Succeeded ]]; then
                succeeded=true
                break
            elif [[ "$phase" == Failed || "$phase" == Error ]]; then
                printf 'Argo sync %s failed\n' "$round" >&2
                exit 1
            fi
        fi
        sleep 2
    done
    [[ "$succeeded" == true ]] || { printf 'Argo sync %s timed out\n' "$round" >&2; exit 1; }
    job_uid="$(kubectl -n "$app_namespace" get job gitops-lightdash-migrate -o jsonpath='{.metadata.uid}')"
    [[ "$job_uid" != "$previous_job_uid" ]] || { printf 'Migration hook did not rerun\n' >&2; exit 1; }
    previous_job_uid="$job_uid"
    expected=5
    [[ "$round" == 1 ]] && expected=0
    kubectl -n "$app_namespace" logs job/gitops-lightdash-migrate -c migrate | \
        grep -Fx "MIGRATION_BARRIER_OK deployments=$expected"
    kubectl -n "$app_namespace" get deployments -l app.kubernetes.io/instance=gitops -o json | \
        jq -e '.items | length == 5 and all(.[]; .spec.replicas > 0)' >/dev/null
    for deployment in $(kubectl -n "$app_namespace" get deployments -l app.kubernetes.io/instance=gitops -o name); do
        kubectl -n "$app_namespace" rollout status "$deployment" --timeout=120s
    done
    [[ "$(kubectl -n "$app_namespace" get deployment gitops-lightdash-backend -o jsonpath='{.spec.replicas}')" == 2 ]]
    kubectl -n "$app_namespace" get hpa gitops-lightdash >/dev/null
    [[ "$(kubectl -n "$app_namespace" get pods -l app.kubernetes.io/instance=unrelated -o jsonpath='{.items[0].metadata.uid}')" == "$sentinel_uid" ]]
    printf 'PASS: Argo sync %s, migration barrier and workload restoration\n' "$round"
done
