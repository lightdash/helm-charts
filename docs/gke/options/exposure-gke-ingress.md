# Option: GKE Ingress with managed HTTPS

[Return to the main guide](../../gke-production-deployment-guide.md#9-choose-how-users-reach-lightdash)

This production option creates an external Google Cloud HTTP(S) load balancer,
reserves a stable global IPv4 address, uses a Google-managed TLS certificate, and
redirects HTTP to HTTPS.

You must control the DNS zone for `$LIGHTDASH_DOMAIN`. Reserve the IP before Helm
creates the Ingress so the address does not change later.

## 1. Reserve the address

```bash
export INGRESS_IP_NAME="lightdash-ingress-ip"

gcloud compute addresses create "$INGRESS_IP_NAME" \
  --ip-version=IPV4 \
  --network-tier=PREMIUM \
  --global

export INGRESS_IP="$(gcloud compute addresses describe "$INGRESS_IP_NAME" \
  --global --format='value(address)')"
echo "Create this DNS record: $LIGHTDASH_DOMAIN A $INGRESS_IP"
```

## 2. Create the DNS A record

At your DNS provider, create:

```text
Type:  A
Name:  the host portion of LIGHTDASH_DOMAIN
Value: INGRESS_IP
TTL:   300 while setting up, then your normal production TTL
```

Wait until public DNS returns the reserved address:

```bash
dig +short A "$LIGHTDASH_DOMAIN"
```

Do not add an AAAA record unless you have intentionally configured IPv6. A wrong
AAAA record can prevent managed certificate provisioning.

## 3. Prepare the values fragment

```bash
cp docs/gke/values/exposure-gke-ingress.yaml \
  .context/gke/exposure-values.yaml
sed -i '' "s/REPLACE_LIGHTDASH_DOMAIN/$LIGHTDASH_DOMAIN/g" \
  .context/gke/exposure-values.yaml
```

The fragment deliberately uses the legacy
`kubernetes.io/ingress.class: gce` annotation required by the GKE Ingress
controller, a `ClusterIP` Service, `/api/v1/readyz` for backend health, and a
FrontendConfig for HTTPS redirects.

Continue through validation and Helm installation in the main guide.

## 4. Wait for the load balancer and certificate

Provisioning can take many minutes after the Ingress and correct DNS record both
exist:

```bash
kubectl -n "$NAMESPACE" get ingress lightdash --watch
```

In another terminal:

```bash
kubectl -n "$NAMESPACE" describe managedcertificate lightdash-managed-cert
kubectl -n "$NAMESPACE" describe backendconfig lightdash
kubectl -n "$NAMESPACE" describe ingress lightdash
```

Wait for the managed certificate domain status to become `Active` and for the
Ingress address to equal `$INGRESS_IP`. Do not repeatedly delete and recreate the
certificate; that restarts provisioning.

## 5. Verify HTTPS and health

```bash
curl -sSI "http://$LIGHTDASH_DOMAIN/" | head
curl -fsS "https://$LIGHTDASH_DOMAIN/api/v1/livez"
curl -fsS "https://$LIGHTDASH_DOMAIN/api/v1/readyz"
openssl s_client -connect "$LIGHTDASH_DOMAIN:443" \
  -servername "$LIGHTDASH_DOMAIN" </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

The HTTP request should redirect to HTTPS, both endpoints should succeed, and the
certificate must be valid for the domain.

## Teardown note

Uninstall Helm first and wait for the load balancer resources to disappear. Only
then delete the global IP if it is no longer needed:

```bash
gcloud compute addresses delete "$INGRESS_IP_NAME" --global
```

Deleting the address is irreversible and a future address will differ. Remove
the DNS record after traffic is intentionally retired.

References: [GKE Ingress](https://cloud.google.com/kubernetes-engine/docs/concepts/ingress),
[Google-managed certificates](https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs),
and [HTTP-to-HTTPS redirects](https://cloud.google.com/kubernetes-engine/docs/how-to/ingress-configuration#https_redirect).
