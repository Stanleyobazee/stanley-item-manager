# Stanley's Item Manager

A simple three-tier application (Frontend → Backend → PostgreSQL) containerized with Docker and deployed to Kubernetes via Minikube.

## Deployment Paths

Two independent, parallel paths — same app, same Helm chart, different targets. Each
follows the same shape:

```
GitHub repo
    │
    ├── push to main ─────────► ci-cd.yaml ─────────► SSH + helm ─────────► EC2 + Minikube
    │
    └── workflow_dispatch ────► deploy-eks.yaml ────► OIDC + helm ─────────► AWS EKS
```

| | Minikube / EC2 (primary) | AWS EKS (session-based) |
|---|---|---|
| Trigger | Every push to `main` | Manual (`workflow_dispatch`) |
| Values file | `helm/values.yaml` | `helm/values.yaml` + `helm/values-eks.yaml` |
| Images | DockerHub | ECR |
| Cost | ~$15-20/month, always on | ~$160/month if left running — see `terraform/README.md` |

The Minikube/EC2 path (documented below) is the primary, always-on environment. The EKS path
(`## EKS Deployment (AWS)` further down) is separate infrastructure, provisioned via
Terraform, meant to be spun up for a session and torn down after — not a replacement.

## Project Structure

```
.
├── frontend/               # Nginx-served static HTML/JS
├── backend/                # Node.js Express REST API
├── k8s/                    # Kubernetes manifests (kubectl apply, one file at a time)
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── postgres.yaml       # StatefulSet — provisions its own PVC via volumeClaimTemplates
│   ├── postgres-pvc.yaml   # unused (superseded by postgres.yaml's volumeClaimTemplates)
│   ├── backend.yaml        # ClusterIP only — never exposed outside the cluster
│   └── frontend.yaml
├── helm/                   # Helm chart — templated equivalent of k8s/, deploy as one release
│   ├── Chart.yaml
│   ├── values.yaml         # Minikube path (default)
│   ├── values-eks.yaml     # EKS path overrides — see terraform/README.md
│   ├── helm-deployment.md
│   ├── templates/
│   ├── eks/
│   │   └── storageclass-gp3.yaml   # applied once via kubectl, EKS only
│   └── monitoring/         # Prometheus + Grafana stack — see helm/monitoring/README.md
│       ├── README.md
│       ├── values-monitoring.yaml
│       ├── values-monitoring-eks.yaml   # EKS overrides — Alertmanager SMTP via CSI, not --set
│       ├── values-postgres-exporter.yaml
│       ├── servicemonitor.yaml
│       ├── alert-rules.yaml
│       ├── grafana-dashboard.json
│       └── eks/
│           └── secretprovider-alertmanager.yaml   # applied once via kubectl, EKS only
├── terraform/              # AWS infra for the EKS path (VPC, EKS, ECR, IAM/OIDC, Secrets Manager) — see terraform/README.md
├── SECRETS.md              # OIDC + Secrets Manager guide for the EKS path
├── deploy/                 # Host-level deploy helpers (e.g. systemd units)
│   └── item-manager-frontend-forward.service
└── .github/workflows/      # GitHub Actions CI/CD
    ├── ci-cd.yaml          # Minikube/EC2 path — auto-deploys on push to main
    └── deploy-eks.yaml     # EKS path — manual (workflow_dispatch) only
```

## EKS Deployment (AWS)

A separate, parallel deployment path to AWS EKS via Terraform — alongside, not replacing,
the Minikube/EC2 path documented below. **Read `terraform/README.md` first** — EKS has a
real, unavoidable ~$73/month fixed cost (the control plane, plus a NAT Gateway) that can't be
paused the way the EC2 box can, only torn down via `terraform destroy`. See `SECRETS.md` for
how GitHub OIDC and AWS Secrets Manager work together on this path.

## Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/)
- [Node.js 20+](https://nodejs.org/) (for running the backend locally/tests)

## Backend

```bash
cd backend
npm install
npm test    # runs the Jest/Supertest suite
npm start   # requires a reachable Postgres (see env vars in index.js)
```

Environment variables (all optional, defaults shown):

| Variable | Default | Description |
|---|---|---|
| `PORT` | `3000` | Port the API listens on |
| `PGHOST` | `localhost` | Postgres host |
| `PGPORT` | `5432` | Postgres port |
| `PGUSER` | `postgres` | Postgres user |
| `PGPASSWORD` | `postgres` | Postgres password |
| `PGDATABASE` | `itemsdb` | Postgres database name |
| `CORS_ORIGIN` | `*` | Allowed origin for browser requests |

## Frontend

Plain static HTML/JS served by nginx — no build step. In Kubernetes, nginx proxies `/api/` requests to the backend's `ClusterIP` Service internally (see `frontend/nginx.conf`), so no backend URL needs to be baked in for that deployment path.

For standalone local testing without Kubernetes (no internal DNS available), pass an absolute `BACKEND_URL` at build time instead:

```bash
cd frontend
docker build --build-arg BACKEND_URL=http://localhost:3000 -t item-manager-frontend .
docker run -p 8080:80 item-manager-frontend
```

## CI/CD Setup (GitHub Actions)

Add the following secrets to your GitHub repository (`Settings → Secrets and variables → Actions`):

| Secret | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Your DockerHub username |
| `DOCKERHUB_TOKEN` | Your DockerHub access token |
| `EC2_HOST` | Public IP/hostname of the EC2 instance running Minikube |
| `EC2_SSH_KEY` | Private SSH key (PEM) used to connect to that instance as `ubuntu` |

`.github/workflows/ci-cd.yaml` runs on every push to `main`:
1. Runs backend unit tests
2. Builds and pushes `item-manager-backend` and `item-manager-frontend` images to DockerHub
3. SSHes into the EC2 instance (cloning the repo first if it's not there yet), pulls the latest code, runs `helm upgrade --install item-manager ./helm` (picks up any `values.yaml`/template changes, and installs from scratch if the release doesn't exist), then rolls out the new images with `kubectl rollout restart`

Steps 2 and 3 only run on pushes to `main` — pull requests only run the tests, so a PR from a fork never touches DockerHub or your EC2 instance.

Since step 3 does `git pull origin main` on the EC2 box, keep that checkout's working tree clean (commit config changes like `helm/values.yaml`'s `corsOrigin` through git rather than editing them only on the instance) — an uncommitted local change there would make the pull fail.

## Deploy to Minikube

`k8s/backend.yaml` and `k8s/frontend.yaml` already point at `stanley80/item-manager-backend:latest` / `stanley80/item-manager-frontend:latest` — update those if you're pushing to a different DockerHub account. The backend is `ClusterIP`-only and the frontend reaches it via nginx's internal `/api/` proxy, so there's no ordering dependency between them — everything can be applied together:

```bash
# Start minikube
minikube start

# Apply all manifests
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/backend.yaml
kubectl apply -f k8s/frontend.yaml

# Wait for pods to be ready
kubectl get pods -n item-manager -w

# Access the frontend
minikube service item-manager-frontend-service -n item-manager
```

`postgres.yaml` is a StatefulSet — it provisions its own PVC via `volumeClaimTemplates`, so `k8s/postgres-pvc.yaml` is unused (kept only for reference).

**Alternative: deploy via Helm.** Instead of applying each manifest above by hand, install the chart in `helm/` as one release:
```bash
helm install item-manager ./helm --namespace item-manager --create-namespace
```
See `helm/helm-deployment.md` for upgrades, `--set` overrides, and uninstalling.

## Updating the App After a New Image Push

If CI/CD's `deploy` job is set up (see above), this happens automatically on every push to `main`. To do it manually — e.g. if you built/pushed an image yourself, or the EC2 instance's `EC2_SSH_KEY` isn't configured yet:

```bash
helm upgrade item-manager ./helm -n item-manager   # picks up any values.yaml/template changes
kubectl rollout restart deployment/item-manager-backend -n item-manager
kubectl rollout restart deployment/item-manager-frontend -n item-manager
```

## Accessing the App on AWS EC2

When running Minikube on an EC2 instance, the NodePort is bound to Minikube's internal VM IP and is not reachable from outside. Use `kubectl port-forward` to expose the frontend through the EC2's public IP instead.

**1. Forward the frontend service to port 8080:**
```bash
kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager
```

**2. Open in your browser:**
```
http://<EC2_PUBLIC_IP>:8080
```

**3. Allow port 8080 in your EC2 Security Group (inbound rule):**

| Type | Protocol | Port | Source |
|---|---|---|---|
| Custom TCP | TCP | 8080 | 0.0.0.0/0 (or your IP) |

**4. To keep it running after disconnecting from the terminal — recommended: install it as a systemd service** so it survives disconnects, crashes, and reboots without a terminal open at all:
```bash
which kubectl   # confirm this matches deploy/item-manager-frontend-forward.service's ExecStart path

sudo cp deploy/item-manager-frontend-forward.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now item-manager-frontend-forward.service
sudo systemctl status item-manager-frontend-forward.service
```
Logs: `journalctl -u item-manager-frontend-forward.service -f`

Manual alternatives, if you'd rather not install a systemd unit:
```bash
# Using nohup
nohup kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager &

# Or using tmux
tmux new -s portforward
kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager
# Press Ctrl+B then D to detach
```

The backend Service is `ClusterIP` (internal-only) — it's never reachable from outside the cluster, so it needs no port-forward and no Security Group rule of its own.

## CORS Configuration

The backend restricts which frontend origins can make API requests. This prevents malicious websites from calling your API on behalf of your users.

The allowed origin is set via `CORS_ORIGIN` in `k8s/configmap.yaml`. Before deploying, update it to match your actual frontend URL:

```yaml
CORS_ORIGIN: "http://<EC2_PUBLIC_IP>:8080"
```

How it works:

| Request from | Allowed? |
|---|---|
| Your frontend URL | ✅ Yes |
| Any other website | ❌ No (blocked by browser) |

> **Note:** CORS is enforced by the browser only. Tools like `curl` or Postman bypass it entirely. It is not a substitute for authentication — it is one layer of protection.

## Verify

```bash
kubectl get deployments -n item-manager
kubectl get statefulsets -n item-manager
kubectl get services -n item-manager
kubectl get pods -n item-manager
```

## Kubernetes Dashboard (optional)

```bash
minikube addons enable metrics-server   # optional, adds CPU/memory graphs
minikube addons enable dashboard
```

**Don't expose this to the public internet** — Minikube's dashboard addon grants its service account cluster-admin-equivalent access. Access it through an SSH tunnel instead of a public port-forward:

```bash
# On your local machine:
ssh -L 8001:localhost:8001 ubuntu@<EC2_PUBLIC_IP>

# In a separate SSH session to EC2 (bound to localhost only, no --address flag):
kubectl proxy --port=8001

# Get a login token:
kubectl -n kubernetes-dashboard create token kubernetes-dashboard
```

Then open `http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/` in your local browser, choose **Token**, and paste it in. See `GUIDE.md` step 13 for more detail.
