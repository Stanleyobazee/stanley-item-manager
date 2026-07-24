# Stanley's Item Manager

A simple three-tier application (Frontend → Backend → PostgreSQL) containerized with Docker and deployed to Kubernetes via Minikube.

## Project Structure

```
.
├── frontend/               # Nginx-served static HTML/JS
├── backend/                # Node.js Express REST API
├── k8s/                    # Kubernetes manifests
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── postgres-pvc.yaml
│   ├── postgres.yaml
│   ├── backend.yaml
│   └── frontend.yaml
└── .github/workflows/      # GitHub Actions CI/CD
    └── ci.yaml
```

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

Plain static HTML/JS served by nginx — no build step. The backend URL is baked in at Docker build time via `--build-arg BACKEND_URL`:

```bash
cd frontend
docker build --build-arg BACKEND_URL=http://localhost:3000 -t item-manager-frontend .
docker run -p 8080:80 item-manager-frontend
```

## CI/CD Setup (GitHub Actions)

Add the following secrets to your GitHub repository (`Settings → Secrets and variables → Actions`):

| Secret/Variable | Description |
|---|---|
| `DOCKERHUB_USERNAME` | Your DockerHub username |
| `DOCKERHUB_TOKEN` | Your DockerHub access token |
| `BACKEND_URL` (variable) | Externally reachable backend URL baked into the frontend image |

The pipeline runs on every push to `main`:
1. Runs backend unit tests
2. Builds and pushes `item-manager-backend` and `item-manager-frontend` images to DockerHub

## Before Deploying to Kubernetes

Replace `<your-dockerhub-username>` in `k8s/backend.yaml` and `k8s/frontend.yaml` with your actual DockerHub username (or let CI push there and update the manifests to match).

## Deploy to Minikube

```bash
# Start minikube
minikube start

# Apply all manifests in order
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/postgres-pvc.yaml
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/backend.yaml
kubectl apply -f k8s/frontend.yaml

# Wait for pods to be ready
kubectl get pods -n item-manager -w

# Access the frontend
minikube service item-manager-frontend-service -n item-manager
```

## Updating the App After a New Image Push

After CI pushes a new image to DockerHub, trigger a rolling restart:

```bash
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

**4. To keep it running after disconnecting from the terminal:**
```bash
# Using nohup
nohup kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager &

# Or using tmux (recommended)
tmux new -s portforward
kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager
# Press Ctrl+B then D to detach
```

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
kubectl get services -n item-manager
kubectl get pods -n item-manager
```
