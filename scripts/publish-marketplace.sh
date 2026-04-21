#!/usr/bin/env bash
#
# Mirror Lightdash images to the AWS Marketplace ECR and package/push the
# Helm chart for the Containers Anywhere listing.
#
# Marketplace requires every image referenced by the chart to live in the
# Marketplace-managed ECR, so each run:
#   1. Pulls the Lightdash commercial image from GCP and re-pushes to ECR.
#   2. Pulls the browserless/chromium image from GHCR and re-pushes to ECR.
#   3. Packages the chart using values-marketplace.yaml with --app-version
#      set to the Lightdash version being published.
#   4. Pushes the packaged chart to ECR as an OCI artifact.
#
# Prerequisites:
#   - aws, docker, helm, gcloud, yq installed and authenticated
#   - docker logged in to the Marketplace ECR (see MARKETPLACE_REGISTRY)
#   - gcloud authenticated to the lightdash-containers GCP project
#   - the Marketplace product has ECR repos for:
#       lightdash/lightdash-containers
#       lightdash/browserless-chromium
#       lightdash                          (for the Helm chart OCI artifact)
#     Create any missing repos from the product's Repositories tab first.
#
# Usage:
#   VERSION=0.2753.0-commercial ./scripts/publish-marketplace.sh
#
# Environment variables (with defaults):
#   VERSION                    Lightdash version tag (required, e.g. 0.2753.0-commercial)
#   CHART_VERSION              Chart SemVer (default: read from Chart.yaml)
#   AWS_REGION                 default: us-east-1
#   MARKETPLACE_REGISTRY       default: 709825985650.dkr.ecr.us-east-1.amazonaws.com
#   MARKETPLACE_NAMESPACE      default: lightdash
#   SOURCE_IMAGE               default: us-docker.pkg.dev/lightdash-containers/lightdash/lightdash
#   BROWSERLESS_SOURCE_IMAGE   default: ghcr.io/browserless/chromium
#   BROWSERLESS_TAG            default: read from values-marketplace.yaml
#   SKIP_IMAGE_MIRROR          set to 1 to skip image pushes (e.g. chart-only republish)
#   SKIP_CHART_PUBLISH         set to 1 to skip helm package/push

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/../charts/lightdash"
VALUES_FILE="$CHART_DIR/values-marketplace.yaml"

: "${VERSION:?VERSION is required, e.g. VERSION=0.2753.0-commercial}"
AWS_REGION="${AWS_REGION:-us-east-1}"
MARKETPLACE_REGISTRY="${MARKETPLACE_REGISTRY:-709825985650.dkr.ecr.us-east-1.amazonaws.com}"
MARKETPLACE_NAMESPACE="${MARKETPLACE_NAMESPACE:-lightdash}"
SOURCE_IMAGE="${SOURCE_IMAGE:-us-docker.pkg.dev/lightdash-containers/lightdash/lightdash}"
BROWSERLESS_SOURCE_IMAGE="${BROWSERLESS_SOURCE_IMAGE:-ghcr.io/browserless/chromium}"

BROWSERLESS_TAG="${BROWSERLESS_TAG:-$(grep -A1 "browserless-chromium" "$VALUES_FILE" | grep 'tag:' | awk '{print $2}')}"
if [[ -z "$BROWSERLESS_TAG" ]]; then
  echo "Could not determine BROWSERLESS_TAG from $VALUES_FILE" >&2
  exit 1
fi

CHART_VERSION="${CHART_VERSION:-$(grep -E '^version:' "$CHART_DIR/Chart.yaml" | awk '{print $2}')}"

LIGHTDASH_DST="$MARKETPLACE_REGISTRY/$MARKETPLACE_NAMESPACE/lightdash-containers:$VERSION"
BROWSERLESS_DST="$MARKETPLACE_REGISTRY/$MARKETPLACE_NAMESPACE/browserless-chromium:$BROWSERLESS_TAG"

echo "Publishing to Marketplace:"
echo "  Lightdash version   : $VERSION"
echo "  Chart version       : $CHART_VERSION"
echo "  Browserless version : $BROWSERLESS_TAG"
echo "  Registry            : $MARKETPLACE_REGISTRY/$MARKETPLACE_NAMESPACE"
echo

if [[ "${SKIP_IMAGE_MIRROR:-0}" != "1" ]]; then
  echo "==> Mirroring Lightdash image"
  docker pull --platform linux/amd64 "$SOURCE_IMAGE:$VERSION"
  docker tag "$SOURCE_IMAGE:$VERSION" "$LIGHTDASH_DST"
  docker push "$LIGHTDASH_DST"

  echo
  echo "==> Mirroring browserless/chromium image"
  docker pull --platform linux/amd64 "$BROWSERLESS_SOURCE_IMAGE:$BROWSERLESS_TAG"
  docker tag "$BROWSERLESS_SOURCE_IMAGE:$BROWSERLESS_TAG" "$BROWSERLESS_DST"
  docker push "$BROWSERLESS_DST"
fi

if [[ "${SKIP_CHART_PUBLISH:-0}" != "1" ]]; then
  command -v yq >/dev/null || { echo "yq is required (brew install yq)" >&2; exit 1; }

  echo
  echo "==> Packaging chart"
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT

  # Copy the chart into a temp dir so we can rewrite values.yaml without
  # mutating the source. helm package ignores --values, so the overrides
  # must be baked into the chart's values.yaml before packaging.
  CHART_COPY="$WORK_DIR/lightdash"
  cp -r "$CHART_DIR" "$CHART_COPY"

  yq eval-all '. as $item ireduce ({}; . * $item)' \
    "$CHART_COPY/values.yaml" "$VALUES_FILE" > "$WORK_DIR/merged-values.yaml"
  mv "$WORK_DIR/merged-values.yaml" "$CHART_COPY/values.yaml"

  # The overrides file is only for packaging; do not ship it inside the chart.
  rm -f "$CHART_COPY/values-marketplace.yaml"

  # Drop the Helm test templates. They reference busybox (Docker Hub) which
  # AWS Marketplace review rejects. The tests are a dev-convenience smoke
  # check (`helm test`) and not something customers need to run.
  rm -rf "$CHART_COPY/templates/tests"

  helm dependency update "$CHART_COPY"

  # Strip test templates from every pulled subchart tgz. Subchart tests
  # (e.g. browserless-chrome's test-connection) reference busybox on
  # Docker Hub, which AWS Marketplace review rejects even though tests
  # are never run on customer installs.
  for subchart_tgz in "$CHART_COPY/charts"/*.tgz; do
    [[ -f "$subchart_tgz" ]] || continue
    extract_dir="$WORK_DIR/subchart-$(basename "$subchart_tgz" .tgz)"
    mkdir -p "$extract_dir"
    tar xzf "$subchart_tgz" -C "$extract_dir"
    find "$extract_dir" -type d -name tests -exec rm -rf {} + 2>/dev/null || true
    (cd "$extract_dir" && COPYFILE_DISABLE=1 tar czf "$subchart_tgz" */)
  done

  PACKAGE_DIR="$WORK_DIR/package"
  mkdir -p "$PACKAGE_DIR"
  helm package "$CHART_COPY" \
    --app-version "$VERSION" \
    --version "$CHART_VERSION" \
    --destination "$PACKAGE_DIR"

  CHART_PACKAGE="$PACKAGE_DIR/lightdash-$CHART_VERSION.tgz"
  echo "Packaged $CHART_PACKAGE"

  echo
  echo "==> Pushing chart to Marketplace ECR"
  helm registry login --username AWS \
    --password "$(aws ecr get-login-password --region "$AWS_REGION")" \
    "$MARKETPLACE_REGISTRY"

  helm push "$CHART_PACKAGE" "oci://$MARKETPLACE_REGISTRY/$MARKETPLACE_NAMESPACE"
fi

echo
echo "Done."
echo "Next: go to the Marketplace product page, open the Versions tab,"
echo "and register a new version referencing:"
echo "  Image : $LIGHTDASH_DST"
echo "  Chart : oci://$MARKETPLACE_REGISTRY/$MARKETPLACE_NAMESPACE/lightdash:$CHART_VERSION"
