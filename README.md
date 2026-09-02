# Lightdash helm-charts

# Migrating to 1.0.0

The 1.0.0 release contains breaking changes. You **must first update your instance to 0.10.1** before updating to 1.0.0.

# Development

It is recommended to work on this project with VS Code, as the development environment is pre-configured in a [development container](https://code.visualstudio.com/docs/remote/create-dev-container).

For a modular walkthrough that deploys the locally checked-out chart—from `main`, another branch, or a fork—to Google Kubernetes Engine, see [Deploy a local Lightdash Helm chart to GKE](docs/gke-production-deployment-guide.md). The guide lets you choose database, S3-compatible storage, secret, and exposure options; unfinished paths are marked **Coming soon**.

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
