# Looloo Helm deployment

This chart deploys the Looloo API, web app, and Kong gateway as a single release.

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

## Notes

- The API uses the `looloo-api-env` Secret in the `looloo` namespace.
- The web app proxies `/api/*` to Kong within the same namespace.
- Kong is configured as a DB-less gateway and routes `/api` to the internal `looloo-api` service.
- The chart intentionally keeps Kong and the web app in the same release for a single API entrypoint.
