# Lightdash helm-charts

Helm Charts to deploy [lightdash](https://github.com/lightdash/lightdash). 

## Installing Lightdash: 

```
helm repo add lightdash https://lightdash.github.io/helm-charts
helm install lightdash ligthdash/lightdash \
  --set args.lightdashSecret=abc123 \
  ... etc...
```

## 🚧 WARNING 🚧

Please be advised that these helm charts are under rapid development and will be refactored in the very near future.

It is recommended that you use this repository to generate and customize your own manifests (possibly using [helm template](https://helm.sh/docs/helm/helm_template/) until the charts stabilize).
