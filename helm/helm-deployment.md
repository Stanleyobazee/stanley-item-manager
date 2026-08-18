# Helm Deployment - Stanley's Item Manager

This Helm chart packages the entire three-tier application (Frontend → Backend → PostgreSQL) for deployment to any Kubernetes cluster. It's a templated version of the manifests in `k8s/`.

## Chart Structure

```
helm/
├── Chart.yaml              # Chart metadata
├── values.yaml             # Default configuration values (Minikube path)
├── values-eks.yaml         # EKS path overrides — applied on top of values.yaml, not instead of it. See ../terraform/README.md.
├── helm-deployment.md      # This file
├── templates/
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml               # Minikube only when secretsManager.enabled is false (the default)
│   ├── secretproviderclass.yaml  # EKS only — syncs Secrets Manager into the same Secret name/key
│   ├── serviceaccount.yaml       # EKS only — IRSA-annotated
│   ├── postgres.yaml       # StatefulSet provisions its own PVC via volumeClaimTemplates
│   ├── backend.yaml
│   └── frontend.yaml
├── eks/
│   └── storageclass-gp3.yaml   # EKS only — applied once via kubectl, not chart-managed
└── monitoring/             # Prometheus + Grafana stack — separate from this chart,
                             # installed as its own Helm release. See monitoring/README.md.
```

The `secretproviderclass.yaml`/`serviceaccount.yaml`/EKS branches inside `secret.yaml`,
`backend.yaml`, and `postgres.yaml` all render as no-ops unless `secretsManager.enabled` is
explicitly set (only `values-eks.yaml` sets it) — installing with `values.yaml` alone behaves
exactly as it always has.

## Request Flow

What a single "list items" request actually crosses once this chart is installed:

```
Browser
  │  GET http://<frontend-address>/
  ▼
item-manager-frontend-service  (NodePort 30080 on Minikube, LoadBalancer on EKS)
  ▼
frontend Pod (nginx)
  │  GET /api/items  ──►  nginx.conf proxies /api/ internally, no BACKEND_URL baked in
  ▼
item-manager-backend-service  (ClusterIP :3000 — never reachable from outside the cluster)
  ▼
backend Pod (Express)
  │  SELECT * FROM items
  ▼
postgres Service  (headless, ClusterIP: None)
  ▼
postgres-0 Pod (StatefulSet)
  │  reads/writes
  ▼
postgres-storage PVC  (volumeClaimTemplates — standard/gp3 depending on path)
```

The backend Service being `ClusterIP`-only (not `NodePort`/`LoadBalancer`) is deliberate —
the only Service ever meant to be reached from outside the cluster is the frontend's.

## Prerequisites

- [Helm v3](https://helm.sh/docs/intro/install/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/) or any Kubernetes cluster
- [kubectl](https://kubernetes.io/docs/tasks/tools/)

## Before Deploying

**1. Update the CORS origin** in `helm/values.yaml` to match your frontend URL:
```yaml
config:
  corsOrigin: "http://<EC2_PUBLIC_IP>:8080"
```

**2. Update the DB password** in `helm/values.yaml` before deploying to any real environment:
```yaml
secret:
  postgresPassword: "<your-password>"
```

## Install

```bash
# From the project root
helm install item-manager ./helm --namespace item-manager --create-namespace
```

Always pass `--namespace item-manager` — without it, Helm's own release bookkeeping lands in whatever namespace your current `kubectl` context defaults to (usually `default`), even though the chart's templates place the actual resources in `item-manager` regardless. The app still works either way (see `namespace: {{ .Values.namespace }}` in every template), but every later `helm upgrade`/`status`/`uninstall` would then need the matching namespace too, or Helm won't find the release. Simplify this permanently for your shell by setting it as your `kubectl` context default:
```bash
kubectl config set-context --current --namespace=item-manager
```

## Verify

```bash
# Check all resources are created
helm status item-manager -n item-manager

# Watch pods come up
kubectl get pods -n item-manager -w

# Check all resources
kubectl get all -n item-manager
```

## Access the App

```bash
# On Minikube
minikube service item-manager-frontend-service -n item-manager

# On EC2 via port-forward
kubectl port-forward service/item-manager-frontend-service 8080:80 -n item-manager --address 0.0.0.0
```

Then open `http://<EC2_PUBLIC_IP>:8080` in your browser.

## Upgrade

After making changes to `values.yaml` or templates:

```bash
helm upgrade item-manager ./helm
```

After a new image is pushed to DockerHub — `.github/workflows/ci-cd.yaml`'s `deploy` job does this automatically on every push to `main` (via SSH into the EC2 instance), so you normally don't need to run this by hand:

```bash
helm upgrade item-manager ./helm
kubectl rollout restart deployment/item-manager-backend -n item-manager
kubectl rollout restart deployment/item-manager-frontend -n item-manager
```

`helm upgrade` alone re-applies `values.yaml`/template changes but won't restart pods for an unchanged `:latest` tag (no diff in the manifest), which is why the rollout restarts are still needed to force a fresh image pull.

## Override Values at Deploy Time

You can override any value in `values.yaml` without editing the file:

```bash
# Change replica count
helm install item-manager ./helm --set backend.replicas=3

# Change CORS origin
helm install item-manager ./helm --set config.corsOrigin="http://1.2.3.4:8080"

# Change image tag
helm install item-manager ./helm --set backend.tag=v2.0.0
```

## Uninstall

```bash
helm uninstall item-manager
```

> Note: The PersistentVolumeClaim created by the postgres StatefulSet is not deleted automatically. To fully clean up:
> ```bash
> kubectl delete pvc postgres-storage-postgres-0 -n item-manager
> kubectl delete namespace item-manager
> ```

## Configuration Reference

| Parameter | Description | Default |
|---|---|---|
| `namespace` | Kubernetes namespace | `item-manager` |
| `backend.image` | Backend image name | `stanley80/item-manager-backend` |
| `backend.tag` | Backend image tag | `latest` |
| `backend.replicas` | Number of backend pods | `2` |
| `backend.port` | Container/Service port | `3000` |
| `backend.resources` | Pod CPU/memory requests & limits | see `values.yaml` |
| `frontend.image` | Frontend image name | `stanley80/item-manager-frontend` |
| `frontend.tag` | Frontend image tag | `latest` |
| `frontend.replicas` | Number of frontend pods | `2` |
| `frontend.port` | Container/Service port | `80` |
| `frontend.nodePort` | NodePort for frontend service | `30080` |
| `frontend.resources` | Pod CPU/memory requests & limits | see `values.yaml` |
| `postgres.image` | Postgres image name | `postgres` |
| `postgres.tag` | Postgres image tag | `16-alpine` |
| `postgres.storage` | PVC storage size | `1Gi` |
| `postgres.storageClassName` | Storage class for PVC | `standard` |
| `postgres.resources` | Pod CPU/memory requests & limits | see `values.yaml` |
| `config.pgHost` | Postgres service host | `postgres` |
| `config.pgPort` | Postgres port | `5432` |
| `config.pgUser` | Postgres username | `Stanley` |
| `config.pgDatabase` | Postgres database name | `itemsdb` |
| `config.corsOrigin` | Allowed CORS origin | `http://localhost:8080` |
| `secret.postgresPassword` | Postgres password | `password` |
