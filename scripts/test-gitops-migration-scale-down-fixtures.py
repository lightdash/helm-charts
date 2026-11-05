#!/usr/bin/env python3
"""Replace application processes while preserving the chart's migration hooks."""

import copy
import json
import pathlib
import sys

import yaml


source, destination, sentinel_path = map(pathlib.Path, sys.argv[1:])
selector = (
    "app.kubernetes.io/name=lightdash,app.kubernetes.io/instance=gitops,"
    "app.kubernetes.io/component in "
    "(backend,worker,app-build-worker,warehouse-nats-worker,pre-aggregate-nats-worker)"
)
migration_assertion = """
const fs = require('node:fs');
const credentials = '/var/run/secrets/kubernetes.io/serviceaccount';
const namespace = fs.readFileSync(`${credentials}/namespace`, 'utf8').trim();
const token = fs.readFileSync(`${credentials}/token`, 'utf8').trim();
const selector = SELECTOR;
async function get(path) {
  return fetch(`https://kubernetes.default.svc${path}`, {
    headers: {Authorization: `Bearer ${token}`},
    signal: AbortSignal.timeout(30000),
  });
}
async function assertStopped() {
  const query = `?labelSelector=${encodeURIComponent(selector)}`;
  const podResponse = await get(`/api/v1/namespaces/${namespace}/pods${query}`);
  if (!podResponse.ok) throw new Error(`pods: HTTP ${podResponse.status}`);
  const pods = await podResponse.json();
  if (pods.items.length !== 0) throw new Error('Application pods still exist');
  const deploymentResponse = await get(`/apis/apps/v1/namespaces/${namespace}/deployments${query}`);
  if (!deploymentResponse.ok) throw new Error(`deployments: HTTP ${deploymentResponse.status}`);
  const deployments = await deploymentResponse.json();
  if (deployments.items.some((item) => item.spec.replicas !== 0)) {
    throw new Error('Application deployment is not scaled to zero');
  }
  const hpa = await get(`/apis/autoscaling/v2/namespaces/${namespace}/horizontalpodautoscalers/gitops-lightdash`);
  if (hpa.status !== 404) throw new Error(`Backend HPA still exists: HTTP ${hpa.status}`);
  console.log(`MIGRATION_BARRIER_OK deployments=${deployments.items.length}`);
}
assertStopped().catch((error) => { console.error(error); process.exit(1); });
""".replace("SELECTOR", json.dumps(selector))

documents = []
for document in yaml.safe_load_all(source.read_text()):
    if document is None:
        continue
    kind = document["kind"]
    if kind == "Deployment":
        template = document["spec"]["template"]
        template["metadata"].pop("annotations", None)
        template["spec"] = {
            "terminationGracePeriodSeconds": 1,
            "containers": [{
                "name": "application",
                "image": "node:22-alpine",
                "command": ["node", "-e", "setInterval(() => {}, 1000)"],
                "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}},
            }],
        }
        documents.append(document)
    elif kind == "Job" and document["metadata"]["name"] == "gitops-lightdash-migrate":
        pod_spec = document["spec"]["template"]["spec"]
        pod_spec["containers"] = [{
            "name": "migrate",
            "image": "node:22-alpine",
            "command": ["node", "-e", migration_assertion],
            "env": [{"name": "NODE_EXTRA_CA_CERTS", "value": "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"}],
        }]
        documents.append(document)
    elif kind in ("Role", "RoleBinding", "ServiceAccount") and "migration" in document["metadata"]["name"]:
        documents.append(document)
    elif kind == "HorizontalPodAutoscaler":
        documents.append(document)

deployments = [item for item in documents if item["kind"] == "Deployment"]
assert len(deployments) == 5, "Smoke test must include all five application deployments"
job = next(item for item in documents if item["kind"] == "Job")
assert len(job["spec"]["template"]["spec"]["initContainers"]) == 3
assert job["spec"]["template"]["spec"]["initContainers"][1]["command"] == ["node"]
destination.write_text(yaml.safe_dump_all(documents, sort_keys=False))

sentinel = copy.deepcopy(deployments[0])
sentinel["metadata"]["name"] = "unrelated-backend"
sentinel["metadata"]["labels"]["app.kubernetes.io/instance"] = "unrelated"
sentinel["spec"]["replicas"] = 1
sentinel["spec"]["selector"]["matchLabels"]["app.kubernetes.io/instance"] = "unrelated"
sentinel["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/instance"] = "unrelated"
sentinel_path.write_text(yaml.safe_dump(sentinel, sort_keys=False))
