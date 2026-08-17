# Lightdash helm-charts

# Upgrading

The step-by-step upgrade guide lives at [docs/upgrade-guide.md](docs/upgrade-guide.md). It covers the chart 3.0.0 changes, the values edits for common setups, how to verify an upgrade, and how to roll back. You can rehearse your own upgrade in a local kind cluster with the harness in [scripts/rehearsal/](scripts/rehearsal/README.md).

## Migrating to 1.0.0

The 1.0.0 release contains breaking changes. You **must first update your instance to 0.10.1** before updating to 1.0.0.

# Development

It is recommended to work on this project with VS Code, as the development environment is pre-configured in a [development container](https://code.visualstudio.com/docs/remote/create-dev-container).

## Linting
  `ct lint --all`

## Running with minikube

```
# Start minikube (optionally use hyperkit not docker)
minikube start --driver=hyperkit

# Get the lightdash helm charts (this repo)
helm repo add lightdash https://lightdash.github.io/helm-charts

# Pull a specific version of lightdash - (~5 minutes)
minikube image pull lightdash/lightdash:0.433.1

# Use a locally built image of lightdash - (~5 minutes)
minikube image load lightdash/lightdash:0.433.1-alpha

##########
### values.yaml
image:
  tag: latest
service:
  type: NodePort
configMap:
  LIGHTDASH_SECRET: "your-secret"
##########

# Install Lightdash
helm install my-lightdash lightdash/lightdash -f values.yaml

# Get the cluster url for Lightdash
minikube service lightdash --url
