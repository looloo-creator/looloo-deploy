# Looloo Deployment

Helm charts and local Minikube lifecycle scripts for the Looloo web app, API,
Kong Gateway, Prometheus, and Grafana.

## Workspace Layout

The scripts expect this repository alongside the application repositories:

```text
workspace/
  looloo-api/
  looloo-web/
  looloo-deploy/
```

The API repository must contain a local `.env` file. Keep it untracked; the
startup script uses it to create the Kubernetes Secret.

## Local Minikube

From the workspace root, run:

```bash
./looloo-deploy/scripts/start.sh
```

The script builds and loads the local images, starts a host-only relay for the
local PostgreSQL and MongoDB ports, installs the Helm release, and prints the
localhost URL. To stop the Looloo workloads and helper processes:

```bash
./looloo-deploy/scripts/stop.sh
```

See [the chart guide](helm/looloo/README.md) for deployment details and
database network requirements.

## Monitoring

The monitoring stack is a separate Helm chart and release in
`helm/looloo-monitor`. Install the Looloo app chart first, then follow the
[monitoring guide](helm/looloo-monitor/README.md). Keeping it as a separate
release lets monitoring be upgraded or removed independently of the app.