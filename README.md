# OpenNebula Marketplace Driver — `cozyportal`

Custom [OpenNebula Marketplace Driver](https://docs.opennebula.io/6.10/integration_and_development/infrastructure_drivers_development/devel-market.html)
that bridges OpenNebula datastores with the Cozyportal **Files API**
(aggregated Kubernetes API served by `files-apiserver`, S3-backed).

Use cases:

- **Image from Volume** — export a running VM's disk to Cozyportal so users
  can download it, share it across zones, or re-use it as an image.
- **Volume from Image** — materialize a Cozyportal-hosted image into any
  zone's datastore as an OpenNebula `Image` with zero data passing through
  controller pods.

## How it works

```text
              OpenNebula frontend                 Kubernetes (Cozyportal)
  ┌───────────────────────────────┐        ┌────────────────────────────┐
  │ onemarketapp create ──► ds_mad│        │                            │
  │                         export│        │                            │
  │                           │   │        │                            │
  │                           ▼   │  HTTPS │   /apis/files.portal.      │
  │ market/cozyportal/import ─────┼───────►│   cozystack.io/.../upload  │
  │                               │        │                            │
  │ SOURCE=cozyportal://ns/fileid │        │                            │
  └───────────────┬───────────────┘        └────────────────────────────┘
                  │
                  ▼
  ┌───────────────────────────────┐
  │ oneimage create --path SOURCE │
  │        ── ds_mad/cp ──┐       │
  │                       │       │  HTTPS
  │  downloader.sh        │       │
  │   └─ cozyportal:// ───┼───────┼────────► GET /files/<id>/content
  │                       │       │
  └───────────────────────────────┘
```

No data passes through the `opennebula-controller` or `console-controller`
pods — they only orchestrate CRDs. The actual bytes flow `ONE frontend ↔ S3`
through the Files API server.

## Authentication & isolation

The driver authenticates to the aggregated Kubernetes API using a **long-
lived ServiceAccount token** (`one-marketplace` SA in `cozy-files` namespace).

`File` resources are **namespace-scoped** inside Cozyportal — each project
lives in its own `project-*` namespace. To touch a file under
`projects/<ns>/<uuid>`, the SA must have RBAC verbs on that `(namespace,
file)` pair. The `MARKET_DRIVER_ACTION_DATA/MARKETPLACE_APP/TEMPLATE/NAMESPACE`
attribute tells the driver which namespace to target on upload, and the
`cozyportal://<namespace>/<file-uuid>` SOURCE URL carries the namespace on
download.

The ClusterRole in `install/k8s/serviceaccount.yaml` is scoped to the
`files.portal.cozystack.io` API group only — the driver cannot reach any
other resource in the cluster.

## Repository layout

```text
market/cozyportal/          → /var/lib/one/remotes/market/cozyportal/
  import                    — upload local file → Files API
  delete                    — DELETE a File in Files API
  monitor                   — synthetic capacity stats
  cozyportal.lib.sh         — shared helpers

datastore/
  cozyportal_downloader.sh  → /var/lib/one/remotes/datastore/

etc/market/cozyportal/
  cozyportal.conf           → /var/lib/one/remotes/etc/market/cozyportal/

install/
  install.sh                — idempotent installer (run as root on ONE FE)
  cozyportal.market         — template for onemarket create
  k8s/serviceaccount.yaml   — SA, ClusterRole, token secret
```

## Installation

Install in two steps: set up Kubernetes RBAC, then configure the OpenNebula
frontend.

### 1. Kubernetes-side (run on any machine with `kubectl`)

```bash
kubectl apply -f install/k8s/serviceaccount.yaml

# Extract the long-lived token and the Kubernetes CA:
kubectl -n cozy-files get secret one-marketplace-token \
    -o jsonpath='{.data.token}' | base64 -d > /tmp/cp.token
kubectl -n cozy-files get secret one-marketplace-token \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/cp.ca.crt
```

Copy `cp.token` and `cp.ca.crt` to the OpenNebula frontend securely, e.g.:

```bash
scp /tmp/cp.token  user@onefrontend:/tmp/cp.token
scp /tmp/cp.ca.crt user@onefrontend:/tmp/cp.ca.crt
```

### 2. OpenNebula-side (run on the ONE frontend)

```bash
git clone <this repo> /opt/one-market-cozyportal
cd /opt/one-market-cozyportal
sudo ./install/install.sh

# Install the token/CA into the oneadmin-owned directory:
sudo install -o oneadmin -g oneadmin -m 0600 /tmp/cp.token  /var/lib/one/.cozyportal/token
sudo install -o oneadmin -g oneadmin -m 0644 /tmp/cp.ca.crt /var/lib/one/.cozyportal/ca.crt

# Point the driver at the in-cluster Kubernetes API endpoint that is
# reachable from the ONE frontend, and uncomment COZYPORTAL_CACERT to trust
# the CA we just installed:
sudo vi /var/lib/one/remotes/etc/market/cozyportal/cozyportal.conf

sudo systemctl restart opennebula
sudo -u oneadmin onemarket create /opt/one-market-cozyportal/install/cozyportal.market
```

Verify:

```bash
sudo -u oneadmin onemarket show cozyportal
# → STATE should transition to MONITORED once onemonitord runs the monitor script.
```

## End-to-end test (manual, via `one*` CLI)

The driver is exercised entirely through OpenNebula's own tooling — no
Cozyportal console workflow needed for the smoke test.

1. **Pre-create a File in the target Cozyportal project**

   ```bash
   FILE_UUID=$(uuidgen | tr A-Z a-z)
   NS=project-<project-uuid>

   cat <<EOF | kubectl apply -f -
   apiVersion: files.portal.cozystack.io/v1alpha1
   kind: File
   metadata:
     name: $FILE_UUID
     namespace: $NS
   spec:
     filename: exported-image.qcow2
     contentType: application/octet-stream
     size: "1073741824"  # upper bound; actual size is overwritten on upload
   EOF
   ```

2. **Upload** — create a MarketPlaceApp that points at an existing ONE Image
   and at the pre-created File:

   ```bash
   cat > /tmp/app.tmpl <<EOF
   NAME      = "demo-app"
   ORIGIN_ID = "1"          # ONE Image id
   TYPE      = "IMAGE"
   NAMESPACE = "$NS"
   FILE_ID   = "$FILE_UUID"
   EOF
   sudo -u oneadmin onemarketapp create --marketplace cozyportal /tmp/app.tmpl
   ```

   Wait for `STATE=rdy` on `onemarketapp show <id>`. The SOURCE attribute
   should read `cozyportal://<NAMESPACE>/<FILE_ID>`. Inspect the
   corresponding Cozyportal File — `status.phase` will be `Ready` and
   `status.size`/`status.sha256` will be populated.

3. **Download** — export the MarketPlaceApp back into any datastore:

   ```bash
   sudo -u oneadmin onemarketapp export <app-id> demo-restored -d default
   ```

   `downloader.sh` picks up the `cozyportal://` scheme and streams the
   content straight from the Files API into the datastore. On completion
   the new Image is `rdy` and `md5sum` matches the original.

## Integration with Cozyportal controllers

A full end-to-end flow ("Image from Volume" / "Volume from Image" triggered
from the console UI) requires two more pieces, which are outside the scope
of this driver repo but depend on it:

- **console-controller** must pre-create the File resource and either invoke
  `onemarketapp create` via the OpenNebula API or (preferred) materialise
  an `opennebula.cozystack.io/MarketplaceAppliance` CR that carries
  `TEMPLATE/NAMESPACE` and `TEMPLATE/FILE_ID`.
- For cross-zone download, `mapping.BuildImageFromImage` must set
  `spec.one.path` to `cozyportal://<ns>/<file-uuid>` whenever the source
  console Image already has a `status.fileRef`. The driver installed here
  handles everything downstream of that setting.

These controller changes are tracked separately from this repo.

## Uninstall

```bash
sudo systemctl stop opennebula
sudo rm -rf /var/lib/one/remotes/market/cozyportal \
           /var/lib/one/remotes/etc/market/cozyportal \
           /var/lib/one/remotes/datastore/cozyportal_downloader.sh \
           /var/lib/one/.cozyportal
# Manually revert the MARKET_MAD ARGUMENTS and drop the MARKET_MAD_CONF
# block from /etc/one/oned.conf (backups with .cozyportal.bak.* timestamps
# were created during install).
sudo systemctl start opennebula
```

## License

Apache-2.0.
