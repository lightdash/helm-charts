# Recipes

Each recipe is a single, self-contained file that takes one path from an empty
environment to a running Lightdash. Follow one top to bottom; there are no
choices to make part-way through.

| Recipe | Cluster | Database | Secrets | Use it for |
|---|---|---|---|---|
| [Local Kind + Vault Secrets Operator](local-kind-vault-vso.md) | Kind (disposable) | Bundled PostgreSQL | Vault dev server + VSO | Learning or testing the chart's `secretRefs` support on a laptop |

Recipes deploy `./charts/lightdash` from the currently checked-out commit, not
the published `lightdash/lightdash` chart, so they exercise unreleased changes.

Working files go in `.context/`, which this repository ignores. Nothing a recipe
creates is committed.
