# Build, Test & Deploy Guide

Everything you need to take Stanley's Item Manager from a clean checkout to a running app on Minikube (and, optionally, EC2), in order. Copy/paste commands as you go — all paths are relative to the repo root unless noted.

---

## 0. Prerequisites

- [Node.js 20+](https://nodejs.org/) and npm
- [Docker](https://docs.docker.com/get-docker/)
- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- A [DockerHub](https://hub.docker.com/) account (only needed if you want CI to push images, or you want to push manually)

Check they're all installed:

```bash
node -v
docker -v
minikube version
kubectl version --client
```

---

## 1. Backend — install, test, run locally

```bash
cd backend
npm install
npm test
```

`npm test` runs Jest + Supertest against `/health`, and the input-validation paths of `/api/items` — it does **not** need a live Postgres connection.

To run the API for real, start a local Postgres first (or point at one you already have):

```bash
docker run --name item-manager-postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=itemsdb -p 5432:5432 -d postgres:16-alpine
```

Then start the backend:

```bash
npm start
```

It listens on `http://localhost:3000` by default. Check it:

```bash
curl http://localhost:3000/health
curl http://localhost:3000/api/items
curl -X POST http://localhost:3000/api/items -H "Content-Type: application/json" -d "{\"name\":\"Widget\",\"description\":\"A test item\"}"
```

Env vars it respects (all optional): `PORT`, `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`, `CORS_ORIGIN`.

When done, stop the throwaway Postgres container:

```bash
docker rm -f item-manager-postgres
```

---

## 2. Frontend — try it locally

The frontend is a static `index.html` (no build step). Easiest way to preview it against your local backend:

```bash
cd frontend
docker build --build-arg BACKEND_URL=http://localhost:3000 -t item-manager-frontend .
docker run --rm -p 8080:80 item-manager-frontend
```

Open `http://localhost:8080` — with the backend from step 1 running, you should be able to add/list/delete items. (You'll see a CORS error in the console unless `CORS_ORIGIN` on the backend allows `http://localhost:8080`; for local testing it's easiest to leave the backend's `CORS_ORIGIN` as the default `*`.)

---

## 3. Build both Docker images

```bash
# from repo root
docker build -t item-manager-backend ./backend
docker build --build-arg BACKEND_URL=http://localhost:3000 -t item-manager-frontend ./frontend
```

Sanity-check them together on a shared Docker network:

```bash
docker network create item-manager-net

docker run -d --name postgres --network item-manager-net \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=itemsdb postgres:16-alpine

docker run -d --name backend --network item-manager-net -p 3000:3000 \
  -e PGHOST=postgres -e PGPASSWORD=postgres -e PGDATABASE=itemsdb \
  item-manager-backend

docker run -d --name frontend --network item-manager-net -p 8080:80 \
  item-manager-frontend
```

Visit `http://localhost:8080`. Tear it down when done:

```bash
docker rm -f postgres backend frontend
docker network rm item-manager-net
```

---

## 4. Push images to DockerHub (manual)

Only needed if you're not relying on CI to do this for you.

```bash
docker login

docker tag item-manager-backend <your-dockerhub-username>/item-manager-backend:latest
docker tag item-manager-frontend <your-dockerhub-username>/item-manager-frontend:latest

docker push <your-dockerhub-username>/item-manager-backend:latest
docker push <your-dockerhub-username>/item-manager-frontend:latest
```

Then update the `image:` field in `k8s/backend.yaml` and `k8s/frontend.yaml` to match (replace `<your-dockerhub-username>`).

---

## 5. Set up CI/CD (GitHub Actions)

`.github/workflows/ci.yaml` runs backend tests on every push/PR, and on pushes to `main` it builds and pushes both images to DockerHub.

In your GitHub repo, go to **Settings → Secrets and variables → Actions** and add:

| Type | Name | Value |
|---|---|---|
| Secret | `DOCKERHUB_USERNAME` | your DockerHub username |
| Secret | `DOCKERHUB_TOKEN` | a DockerHub access token (not your password) |
| Variable | `BACKEND_URL` | the externally reachable backend URL to bake into the frontend image, e.g. `http://<EC2_PUBLIC_IP>:30800` |

Push to `main` and watch the **Actions** tab. Once it's green, images land at:
- `docker.io/<DOCKERHUB_USERNAME>/item-manager-backend:latest`
- `docker.io/<DOCKERHUB_USERNAME>/item-manager-frontend:latest`

---

## 6. Deploy to Minikube

Start the cluster:

```bash
minikube start
```

Before applying, make sure `k8s/backend.yaml` and `k8s/frontend.yaml` point at real images (either ones you pushed in step 4, or ones CI pushed in step 5) — replace `<your-dockerhub-username>`.

Apply manifests **in this order** (later ones depend on earlier ones):

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/postgres-pvc.yaml
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/backend.yaml
kubectl apply -f k8s/frontend.yaml
```

Watch pods come up:

```bash
kubectl get pods -n item-manager -w
```

Press Ctrl+C once everything shows `Running`/`1/1`.

Open the app:

```bash
minikube service item-manager-frontend-service -n item-manager
```

---

## 7. Verify everything

```bash
kubectl get deployments -n item-manager
kubectl get services -n item-manager
kubectl get pods -n item-manager
```

Check backend health directly:

```bash
kubectl port-forward service/item-manager-backend-service 3000:3000 -n item-manager
curl http://localhost:3000/health
```

Check logs if something looks wrong:

```bash
kubectl logs -n item-manager deployment/item-manager-backend
kubectl logs -n item-manager deployment/item-manager-frontend
kubectl logs -n item-manager deployment/postgres
```

---

## 8. Update the app after a new image push

Whenever CI (or you, manually) pushes a new `:latest` image, Kubernetes won't automatically pick it up — trigger a rolling restart:

```bash
kubectl rollout restart deployment/item-manager-backend -n item-manager
kubectl rollout restart deployment/item-manager-frontend -n item-manager
kubectl rollout status deployment/item-manager-backend -n item-manager
kubectl rollout status deployment/item-manager-frontend -n item-manager
```

---

## 9. Accessing the app on AWS EC2

`minikube service` won't work from outside the EC2 instance (it binds to Minikube's internal VM IP). Use `kubectl port-forward` bound to all interfaces instead.

```bash
kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager
```

Then browse to `http://<EC2_PUBLIC_IP>:8080`.

Open port 8080 in your EC2 Security Group (inbound rule):

| Type | Protocol | Port | Source |
|---|---|---|---|
| Custom TCP | TCP | 8080 | 0.0.0.0/0 (or your IP) |

Keep the port-forward alive after disconnecting:

```bash
# Option A: nohup
nohup kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager &

# Option B: tmux (recommended)
tmux new -s portforward
kubectl port-forward service/item-manager-frontend-service 8080:80 --address 0.0.0.0 -n item-manager
# Ctrl+B then D to detach; `tmux attach -t portforward` to come back
```

Remember: the frontend image needs to have been built with `BACKEND_URL` pointing at a backend address reachable from the browser (e.g. `http://<EC2_PUBLIC_IP>:30800`, the backend's NodePort) — see step 5's `BACKEND_URL` variable, or rebuild manually with `--build-arg BACKEND_URL=...`.

---

## 10. CORS configuration

The backend only accepts browser requests from the origin set in `CORS_ORIGIN` (in `k8s/configmap.yaml`). Before deploying somewhere real, update it to match wherever the frontend is actually served from:

```yaml
CORS_ORIGIN: "http://<EC2_PUBLIC_IP>:8080"
```

Then re-apply and restart:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl rollout restart deployment/item-manager-backend -n item-manager
```

`curl`/Postman bypass CORS entirely — it's a browser-enforced guard, not authentication.

---

## 11. Common troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `npm ci` fails in Docker build | `package-lock.json` missing or out of sync — run `npm install` in `backend/` and commit the lockfile |
| Backend pod `CrashLoopBackOff` | Check `kubectl logs -n item-manager deployment/item-manager-backend` — usually can't reach Postgres yet (it retries 10x with backoff, then exits) |
| Postgres pod stuck `Pending` | PVC can't be bound — check `kubectl get pvc -n item-manager` and your storage class |
| Frontend loads but items never appear, console shows CORS error | `CORS_ORIGIN` on the backend doesn't match the frontend's origin — see step 10 |
| Frontend loads but network calls go to the wrong host | Frontend image was built with the wrong `BACKEND_URL` — rebuild with the correct `--build-arg` |
| `minikube service` hangs / not reachable on EC2 | Use `kubectl port-forward --address 0.0.0.0` instead (step 9) |

---

## 12. Tear down

```bash
kubectl delete namespace item-manager
minikube stop
```

`kubectl delete namespace item-manager` removes every resource created above (deployments, services, configmap, secret, PVC) in one shot — the PVC's underlying data goes with it, so make sure you don't need it first.
