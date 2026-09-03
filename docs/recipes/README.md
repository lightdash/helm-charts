# Recipes

Each recipe is a single, self-contained file that takes one path from an empty
environment to a running Lightdash. Follow one top to bottom; there are no
choices to make part-way through.

| Recipe | Cluster | Database | Secrets |
|---|---|---|---|
| [Local Kind + Vault Secrets Operator](local-kind-vault-vso.md) | Kind — local Kubernetes in Docker, disposable | Bundled PostgreSQL | Vault dev server + VSO |
| [Docker Desktop + external PostgreSQL](docker-desktop-external-postgres-vault-vso.md) | Docker Desktop's built-in Kubernetes | External, not managed by the chart | Vault dev server + VSO |

Recipes deploy `./charts/lightdash` from the currently checked-out commit, not
the published `lightdash/lightdash` chart, so they exercise unreleased changes.

Working files go in `.context/`, which this repository ignores. Nothing a recipe
creates is committed.
