# Looloo Monitoring

Helm chart for Prometheus and Grafana, with Kubernetes state and Minikube node
exporters plus scrape targets for the Looloo API and Kong.

## Install

From the workspace root, use the local launcher to install or upgrade this
release and open Grafana on an available localhost port:

```bash
./looloo-deploy/scripts/start-monitor.sh
```

Use `./looloo-deploy/scripts/stop-monitor.sh` to stop the monitoring release
and its local port-forward. For direct Helm installation, first install the Looloo
application chart. Its API Service must expose the `metrics` port and Kong must
have its Prometheus plugin enabled. Then run from the workspace root:

```bash
helm dependency update ./looloo-deploy/helm/looloo-monitor
helm upgrade --install looloo-monitor ./looloo-deploy/helm/looloo-monitor \
  --namespace monitoring --create-namespace --wait=false
kubectl -n monitoring rollout status statefulset/prometheus-looloo-monitor-kube-promet-prometheus
kubectl -n monitoring rollout status deployment/looloo-monitor-grafana
```

Open Grafana locally if you did not use `start-monitor.sh`:

```bash
kubectl -n monitoring port-forward service/looloo-monitor-grafana 13001:80
```

Visit `http://localhost:13001`. The kube-prometheus-stack chart provisions the
Prometheus datasource and Kubernetes dashboards. The local admin username is
`admin`; retrieve the generated password from the Kubernetes Secret:

```bash
kubectl -n monitoring get secret looloo-monitor-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode; echo
```

Configure a unique Grafana admin password before exposing Grafana beyond local
development.

## Metrics Collected

- API: HTTP request totals and latency, Node.js process/runtime metrics.
- Kong: request status, latency, bandwidth, and upstream health metrics.
- Minikube: Kubernetes object state and node-exporter host metrics.

Minikube binds scheduler, controller-manager, and etcd metrics to node loopback
by default, which is not reachable from a normal Prometheus pod. Those three
scrape jobs are disabled here; API server, kubelet, kube-proxy, node-exporter,
and kube-state-metrics remain monitored.

The API metrics listener is on an internal-only Service port and is not routed
through Kong's public API route. Prometheus retains three days of data by
default to keep local storage usage bounded.