# Upgrade rehearsal

The rehearsal harness installs and upgrades Lightdash in a local kind cluster. It uses the released Helm chart as the starting point. It uses the chart in this repository as the default target.

The harness creates a bundled PostgreSQL database. It pins both database passwords. It also creates a local MinIO service and the required bucket. The same values reach the backend and the migration Job.

## Requirements

Install these tools before you run the harness:

- `kind`
- `kubectl`
- `helm`
- `jq`
- `docker`

The harness does not require `kind` or `docker` with `--skip-cluster`.

### Apple Silicon

Lightdash images can publish without an ARM64 manifest. The harness checks the image for each side of the upgrade on an Apple Silicon host. It pulls a missing image as `linux/amd64` and loads it into kind.

Enable Rosetta for x86 and AMD64 emulation in Docker Desktop settings. The harness checks the kind node for an x86_64 binfmt handler. It stops before Helm install when the handler is absent.

The Apple Silicon image loader reads each chart `appVersion`. An `image.tag` in the rehearsal values takes precedence.

## Run an upgrade

Run the default rehearsal from the repository root:

```bash
scripts/rehearsal/rehearse.sh
```

The default command installs the newest released chart older than the target chart. It upgrades the release to `charts/lightdash`. It seeds the database and the product API. It monitors traffic during the upgrade. It then checks the release, migrations, migration ledger, backend rollout, readiness, traffic, marker row, and user login.

The default rehearsal does not override the backend readiness path. It tests the chart defaults for both install and upgrade.

Use an older released chart as the starting point:

```bash
scripts/rehearsal/rehearse.sh --from 2.10.200
```

Use a released chart as the target:

```bash
scripts/rehearsal/rehearse.sh --to 2.10.257
```

Run a fresh install without an upgrade:

```bash
scripts/rehearsal/rehearse.sh --install-only
```

## Options

```text
--from <chart-version|latest>          Default: newest release older than target
--to <chart-version|local>             Default: local
--allow-non-forward                    Allow an equal-version or downgrade rehearsal
--values <file>                        Default: scripts/rehearsal/values/rehearsal.yaml
--install-only                         Install the target, seed it, and assert it
--drill <name>                         Run one failure drill
--cluster-name <name>                  Default: lightdash-rehearsal
--kind-image <kindest/node:vX.Y.Z>     Pass a node image to kind
--skip-cluster                         Use the current kubectl context
--keep                                 Keep a created kind cluster
--allowed-drops <n>                    Default: 0
```

`--install-only` and `--drill` cannot run together. A drill always uses the default rehearsal values. A drill rejects a custom values file.

The default source is the newest released chart older than the resolved target chart. Upgrade rehearsals reject an equal or newer source unless you pass `--allow-non-forward` explicitly.

Custom-values rehearsals cover bundled-PostgreSQL installs only. The SQL assertions connect directly to the bundled PostgreSQL pod. External-database values are not supported.

The script locates the repository from its own path. You can run it from any working directory.

## Reuse a cluster

Keep the cluster after a run:

```bash
scripts/rehearsal/rehearse.sh --keep
```

Reuse the current context during development:

```bash
scripts/rehearsal/rehearse.sh --skip-cluster
```

Use `--skip-cluster` only with a disposable context. The harness installs resources in the `default` namespace.

## Failure drills

Run a parked migration drill:

```bash
scripts/rehearsal/rehearse.sh --from <older-version> --drill parked-migration
```

This drill enables the migration Job. It rejects migration DDL. It checks the parked ledger, lease state, and `migration_parked` readiness warning. It also checks that the old backend stays available.

Run a killed migrator drill:

```bash
scripts/rehearsal/rehearse.sh --from <older-version> --drill killed-migrator
```

This drill pauses migration DDL. It deletes the active migration pod. It checks that a replacement takes the lease and finishes within about 90 seconds.

Run a slow migration drill:

```bash
scripts/rehearsal/rehearse.sh --from <older-version> --drill slow-migration
```

This drill pauses one migration for four minutes. It raises the startup probe failure threshold to 60. It checks that the new backend pod does not restart.

The migration drills need a real pending migration. Use an older `--from` version when the latest release and the local chart use the same application version. The drill fails with a clear message when no migration runs.

Run the node drain drill:

```bash
scripts/rehearsal/rehearse.sh --drill drain
```

This drill creates one control-plane node and two worker nodes. It pins PostgreSQL and the backend to separate workers. It drains the backend worker and waits for recovery.

The drain drill fails on the current main branch by design. The current PodDisruptionBudget uses `minAvailable: 1` with one backend replica. That budget blocks the eviction until the chart changes.

## Result

The harness exits with status 0 when every assertion passes. It prints a final summary with each `PASS`, `FAIL`, or `SKIP`. It deletes the traffic and client pods on exit. It deletes a created kind cluster unless you pass `--keep`.
