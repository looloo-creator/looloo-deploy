# Looloo Helm deployments

The app and monitoring stacks are separate Helm charts/releases in this repo.
The app chart deploys the Looloo API, web app, and Kong gateway together.

## Install

```bash
helm upgrade --install looloo ./looloo-deploy/helm/looloo \
  --namespace looloo \
  --create-namespace \
  -f ./looloo-deploy/helm/looloo/values-dev.yaml
```

## Update

```bash
helm upgrade looloo ./looloo-deploy/helm/looloo \
  --namespace looloo \
  -f ./looloo-deploy/helm/looloo/values-dev.yaml
```

## Uninstall

```bash
helm uninstall looloo --namespace looloo
```

## Monitoring

After installing the app release, install Prometheus, Grafana, and the
application scrape monitors as a separate release:

```bash
helm dependency update ./looloo-deploy/helm/looloo-monitor
helm upgrade --install looloo-monitor ./looloo-deploy/helm/looloo-monitor \
  --namespace monitoring --create-namespace --wait=false
```

See [the monitoring guide](./looloo-monitor/README.md) for Grafana access and
Minikube-specific scrape limitations.

## Notes

- The API uses the `looloo-api-env` Secret in the `looloo` namespace.
- The web app proxies `/api/*` to Kong within the same namespace.
- Kong is configured as a DB-less gateway and routes `/api` to the internal `looloo-api` service.
- The chart intentionally keeps Kong and the web app in the same release for a single API entrypoint.
