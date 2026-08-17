# Upgrade guide: chart 2.x to 3.0.0

Chart 3.0.0 is not yet released. This guide describes the upgrade path it will require, so you can prepare, and so you can adopt the new behaviour early on the current major. The guide will be finalised with the 3.0.0 release. Every step here is rehearsed by the chart CI and by the rehearsal harness in `scripts/rehearsal/` before we ask anyone to follow it.

## What chart 3.0.0 changes

Chart 3.0.0 changes two default values and nothing else.

- `migrationJob.enabled` changes from `false` to `true`. Database migrations move out of pod startup and into a Helm hook Job that runs before the upgrade. Backend pods start without migrating. This removes the race between pods for the migration lock, and it removes the startup-probe budget as a limit on migration time.
- The backend readiness probe path changes from `/api/v1/health` to `/api/v1/readyz`. The readiness gate holds new pods out of service until the migration completes, and it keeps working pods in service when a migration parks. This replaces `migrate wait` as the mechanism that sequences followers.

Two things do not change, on purpose:

- Worker liveness stays on `/api/v1/health`. Workers serve their own health handler, and a worker restart on a dead pool is the designed recovery path.
- There is no `kubeVersion` constraint.

Chart 3.0.0 also adds a render-time application version floor. `helm template` and `helm upgrade` fail with a clear message when your `image.tag` is older than the floor. Set `versionCheck.enabled: false` to bypass the floor when you must.

## Before you upgrade

1. Record your current state: your chart version (`helm list`), your app version, and your values file.
2. Back up your database. The migration path is forward-only (see Rolling back, below).
3. Run the preflight check from any backend pod. It checks migration safety without changing the database:

   ```bash
   kubectl exec deploy/<release>-backend -- pnpm -F backend migrate-production preflight
   ```

4. Rehearse your own upgrade first if you can. The rehearsal harness runs your exact values file through your exact from-to upgrade in a local kind cluster:

   ```bash
   scripts/rehearsal/rehearse.sh --from <your-current-chart-version> --to <target-version> --values <your-values.yaml>
   ```

   See `scripts/rehearsal/README.md` for requirements.

## Upgrading a default-values install

Run the same command as any chart upgrade:

```bash
helm repo update
helm upgrade <release> lightdash/lightdash --version 3.0.0 -f <your-values.yaml>
```

What happens, in order: the migration Job runs first as a pre-upgrade hook and applies all pending migrations; the backend pods then roll; the readiness gate admits each new pod when the schema is current. You do not need to edit any values.

## Values edits for common setups

**You want to keep the old behaviour.** Pin the old defaults explicitly and nothing changes for you:

```yaml
migrationJob:
  enabled: false
lightdashBackend:
  readinessProbe:
    path: /api/v1/health
```

**You want to adopt the new behaviour today, before 3.0.0.** Set the same two values the other way around on the current major. This is the configuration Lightdash Cloud runs ahead of the major:

```yaml
migrationJob:
  enabled: true
lightdashBackend:
  readinessProbe:
    path: /api/v1/readyz
```

The `readinessProbe.path` value requires a chart version that includes it; check `helm show values lightdash/lightdash` for `lightdashBackend.readinessProbe.path`.

**You run an Enterprise install.** The migration Job runs in its own pod with its own environment. Pass your licence key to the Job, or EE migrations do not run:

```yaml
migrationJob:
  enabled: true
  extraEnv:
    - name: LIGHTDASH_LICENSE_KEY
      valueFrom:
        secretKeyRef:
          name: <your-secret>
          key: LIGHTDASH_LICENSE_KEY
```

**You override probes.** Your existing probe overrides stay in force; defaults never override explicit values. Review the startup probe budget if you keep migrations in pod startup (`migrationJob.enabled: false`): the pod must finish its migrations inside the startup probe window, and the default window is about three minutes. Raise `lightdashBackend.startupProbe.failureThreshold` before a release with a long migration.

**You override the PodDisruptionBudget or replicas.** With one replica, use `maxUnavailable: 1` rather than `minAvailable: 1`, or voluntary evictions (node drains, autoscaler scale-down) deadlock on your namespace.

## Verify the upgrade worked

The chart CI runs these same checks after every rehearsed upgrade.

1. The migration state is clean and the lease is free:

   ```bash
   kubectl exec deploy/<release>-backend -- pnpm -F backend migrate-production status
   ```

2. The backend reports ready:

   ```bash
   kubectl exec deploy/<release>-backend -- curl -s http://localhost:8080/api/v1/readyz
   ```

   A healthy pod returns HTTP 200 with `{"status":"ready"}`.

3. The run ledger recorded the migration run. Query the newest row:

   ```sql
   SELECT started_at, app_version, outcome
   FROM migration_run_ledger
   ORDER BY started_at DESC
   LIMIT 1;
   ```

   The newest row shows `outcome = 'succeeded'` for the app version you deployed. When the upgrade carried no new migrations, no new row appears; that is normal.

## If the migration parks

A migration that fails repeatedly parks instead of crash-looping. Your existing pods keep serving; the parked state fails open for pods that are already working. New pods report `{"status":"not_ready","reason":"migration_parked"}` on `/api/v1/readyz` and stay out of service.

1. Read the failure from the ledger (`failing_migration` and `failure_detail` on the newest row) or from the migration Job logs.
2. Fix the cause.
3. Clear the parked state, attributing the action to yourself:

   ```bash
   kubectl exec deploy/<release>-backend -- pnpm -F backend migrate-production unlock --actor <your-name>
   ```

4. Run the `helm upgrade` again.

## Rolling back

The database schema is forward-only. Do not roll the database back, and do not run the knex rollback scripts against a production database.

The supported mitigation is a code rollback on the newer schema: roll the application image back to the previous version while the migrated schema stays in place.

```bash
helm rollback <release>
```

The application is written so the previous version runs against the newer schema. Verify the rolled-back pods report healthy, then plan a fix forward. Applied migrations stay applied; the next release resumes from where the migration ledger left off.

## Docker Compose installs

The chart and this guide cover Kubernetes. If you run the Docker Compose distribution in production, the same application-level sequence applies on your own tooling: back up the database, pull the new image, run `pnpm -F backend migrate-production up` once before starting the new containers, and verify with `migrate-production status`. Compose is not part of the rehearsed upgrade path.
