# Lightdash helm-charts


# Development

It is recommended to work on this project with VS Code, as the development environment is pre-configured in a [development container](https://code.visualstudio.com/docs/remote/create-dev-container).

## Linting
  `ct lint --all`

## 🚧 WARNING 🚧

Please be advised that these helm charts are under rapid development and will be refactored in the very near future.

It is recommended that you use this repository to generate and customize your own manifests (possibly using [helm template](https://helm.sh/docs/helm/helm_template/) until the charts stabilize).

## Running with minikube

```
# Start minikube (optionally use hyperkit not docker)
minikube start --driver=hyperkit

# Get the lightdash helm charts (this repo)
helm repo add lightdash https://lightdash.github.io/helm-charts


# Pull a specific version of lightdash - (~5 minutes)
minikube image pull lightdash/lightdash:0.511.4

# Use a locally built image of lightdash - (~5 minutes)
minikube image load lightdash/lightdash:0.511.4-alpha

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
