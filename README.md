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

From the workspace root, choose a launcher:

```bash
./looloo-deploy/scripts/start-app.sh      # app only
./looloo-deploy/scripts/start-monitor.sh  # monitoring only; app must already run
./looloo-deploy/scripts/start.sh          # app, then monitoring
```

`start-app.sh` builds and loads the local images, starts a host-only relay for
the local PostgreSQL and Ollama ports, installs the app Helm release, and
prints the app URL. `start-monitor.sh` installs the monitoring release and
opens Grafana in the background; `start.sh` runs both in sequence. To stop just
the app, run `./looloo-deploy/scripts/stop-app.sh`; to stop just monitoring, run
`./looloo-deploy/scripts/stop-monitor.sh`. To stop both:

```bash
./looloo-deploy/scripts/stop.sh
```

The stop scripts remove their associated Helm release/workloads and owned local
helper processes; Minikube itself remains running.

See [the chart guide](helm/looloo/README.md) for deployment details and
database network requirements.

## Monitoring

The monitoring stack is a separate Helm chart and release in
`helm/looloo-monitor`. Install the Looloo app chart first, then follow the
[monitoring guide](helm/looloo-monitor/README.md). From the workspace root,
`./looloo-deploy/scripts/start-monitor.sh` installs or upgrades the stack and
opens Grafana locally. Keeping it as a separate release lets monitoring be
upgraded or removed independently of the app.
