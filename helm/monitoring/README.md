# Monitoring - Stanley's Item Manager

Prometheus + Grafana monitoring for the `item-manager` Kubernetes cluster, built on the
`prometheus-community/kube-prometheus-stack` Helm chart plus this project's own
`ServiceMonitor` and alerting rules. **Read "Resource constraints" below before installing**
this on the same EC2 box the app runs on.

## Directory Structure

```
helm/monitoring/
├── README.md                       # This file — quick command reference
├── values-monitoring.yaml           # Values for the kube-prometheus-stack chart (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics)
├── values-postgres-exporter.yaml    # Values for prometheus-postgres-exporter (separate release)
├── servicemonitor.yaml               # Tells Prometheus to scrape the backend's /metrics
├── alert-rules.yaml                 # PrometheusRule — alerting rules
└── grafana-dashboard.json           # Custom "Item Manager Overview" dashboard
```

## Resource constraints — read this before installing

This project's EC2 instance has reported as low as **~3.8GiB total RAM**, and Minikube's own
node allocation already claims most of that before the app (backend ×2, frontend ×2,
postgres ×1) adds roughly 500Mi more on top. A full Prometheus + Grafana + Alertmanager +
kube-state-metrics + node-exporter + postgres-exporter stack, even trimmed down (see the
resource limits in `values-monitoring.yaml`/`values-postgres-exporter.yaml`), adds
**~600Mi–1.1Gi** more — a real risk of pod evictions or a generally unstable node on this
box, not a hypothetical.

If you install this and see pods pending, evicted, or the node becoming unresponsive:
1. Set `alertmanager.enabled: false` in `values-monitoring.yaml` first — easiest single thing to drop, and Prometheus still shows firing alerts in its own UI without it
2. Temporarily scale the app down (`backend.replicas`/`frontend.replicas` to 1 in `helm/values.yaml`) while monitoring runs
3. Trim resource requests further in both values files
4. Move to a bigger EC2 instance type — the actual long-term fix

## Prerequisites

- [Helm v3](https://helm.sh/docs/intro/install/) and a running `item-manager` deployment (see `../helm-deployment.md`)
- Enough free memory on the node to run this alongside the app — see "Resource constraints" above
- An SMTP account (host, port, username, password/app-password) if you want Alertmanager's email notifications working — any provider works (Gmail app password, SendGrid, your own mail server, etc.)

## Install

**1. Core stack** (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics):
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  -f helm/monitoring/values-monitoring.yaml \
  --set grafana.adminPassword="<a-real-password>" \
  --set alertmanager.config.global.smtp_auth_password="<your-smtp-password>"
```
Before running this, replace the placeholder `smtp_smarthost`/`smtp_from`/`smtp_auth_username`/`receivers[0].email_configs[0].to` values in `values-monitoring.yaml`'s `alertmanager.config` with your real SMTP details — only the password stays out of the file, passed via `--set` above.

**2. Postgres exporter** (separate release, into `item-manager`'s namespace):
```bash
export POSTGRES_PASSWORD="<the same password as helm/values.yaml's secret.postgresPassword>"

helm install postgres-exporter prometheus-community/prometheus-postgres-exporter \
  -n item-manager \
  -f helm/monitoring/values-postgres-exporter.yaml \
  --set-string "extraEnv[0].value=postgresql://Stanley:${POSTGRES_PASSWORD}@postgres.item-manager.svc.cluster.local:5432/itemsdb?sslmode=disable"
```

**3. Backend ServiceMonitor and alert rules:**
```bash
kubectl apply -f helm/monitoring/servicemonitor.yaml
kubectl apply -f helm/monitoring/alert-rules.yaml
```

**4. Grafana dashboard.** kube-prometheus-stack's Grafana ships with a sidecar that
auto-loads any ConfigMap labeled `grafana_dashboard=1` in the `monitoring` namespace — load
`grafana-dashboard.json` that way rather than importing it by hand through the UI:
```bash
kubectl create configmap item-manager-dashboard \
  -n monitoring --from-file=helm/monitoring/grafana-dashboard.json
kubectl label configmap item-manager-dashboard -n monitoring grafana_dashboard=1
```
It'll appear in Grafana within about a minute (the sidecar polls periodically), under
**Dashboards → Item Manager Overview**.

## Verify

```bash
# Everything in the monitoring namespace should be Running
kubectl get pods -n monitoring -w

# postgres-exporter should be Running in item-manager's namespace
kubectl get pods -n item-manager -l app.kubernetes.io/name=prometheus-postgres-exporter

# Confirm the CRDs applied
kubectl get servicemonitor -n item-manager
kubectl get prometheusrule -n item-manager
```

## Accessing Grafana

Grafana's Service is deliberately `ClusterIP`, not a public `NodePort` — it holds an
admin-credentialed UI, and this project already treats admin UIs as SSH-tunnel-only (see the
Kubernetes Dashboard section in `../../GUIDE.md`). Same pattern here:

```bash
# On your local machine:
ssh -L 3000:localhost:3000 ubuntu@<EC2_PUBLIC_IP>

# In a separate SSH session to EC2 (bound to localhost only, no --address flag):
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

Then open `http://localhost:3000` in your local browser. Log in with `admin` / whatever
password you set at install time. Default dashboards for Kubernetes cluster/node/pod metrics
are already loaded via the chart's bundled Grafana dashboard sidecar.

## Application Metrics Available

Exposed by the backend at `/metrics` (`backend/index.js`, via `prom-client`):

| Metric | Type | Description |
|---|---|---|
| `http_requests_total` | Counter | Total HTTP requests, labeled by method/route/status |
| `http_request_duration_seconds` | Histogram | Request latency distribution |
| `http_errors_total` | Counter | Total 4xx/5xx responses |
| `http_active_connections` | Gauge | In-flight requests |
| Node.js default metrics | Various | Event loop lag, heap usage, GC, process CPU/memory |

Every metric carries an `app="item-manager-backend"` label (set once via
`client.register.setDefaultLabels` in `index.js`) — that's what the PromQL examples below and
the `item-manager.application` rules in `alert-rules.yaml` filter on.

## Example PromQL Queries for Grafana

```promql
# Request rate (requests per second)
sum(rate(http_requests_total{app="item-manager-backend"}[5m]))

# Average response latency
sum(rate(http_request_duration_seconds_sum{app="item-manager-backend"}[5m]))
  / sum(rate(http_request_duration_seconds_count{app="item-manager-backend"}[5m]))

# Error rate (percentage)
sum(rate(http_errors_total{app="item-manager-backend"}[5m]))
  / sum(rate(http_requests_total{app="item-manager-backend"}[5m])) * 100

# 95th percentile latency
histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket{app="item-manager-backend"}[5m])))

# In-flight requests right now
http_active_connections{app="item-manager-backend"}
```

## Accessing Prometheus

Same tunnel pattern:

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Open `http://localhost:9090`, then check **Status → Targets** to confirm what's being
scraped, and **Alerts** to see the rules from `alert-rules.yaml` and whether any are firing.

## Uninstall

```bash
kubectl delete -f helm/monitoring/alert-rules.yaml
kubectl delete -f helm/monitoring/servicemonitor.yaml
helm uninstall postgres-exporter -n item-manager
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring
```
