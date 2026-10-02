# Looloo Helm Chart

This chart deploys the Looloo API, web app, and DB-less Kong Gateway into one
namespace. Web requests under `/api/` go through Kong, which strips that prefix
before forwarding them to the API.

## Deploy to Minikube

From the workspace root, `./looloo-deploy/scripts/start.sh` starts the local
stack and prints its localhost URL. Run `./looloo-deploy/scripts/stop.sh` to stop the Looloo
workloads and the helper processes started by the launcher.

For local database testing, the API runs in Minikube and the databases stay on
the host. The API Secret uses `host.minikube.internal` for both database hosts;
the host database services must accept connections from Minikube on those
ports. In another terminal, build/load the app images and install the chart's
development values from the workspace root:

```bash
cd looloo-api && docker build -f Dockerfile.production -t looloo-api:minikube .
cd ../looloo-web && docker build -f Dockerfile.production -t looloo-web:minikube .
cd ..
minikube image load looloo-api:minikube
minikube image load looloo-web:minikube
cd looloo-api && npm run k8s:secrets && cd ..
helm upgrade --install looloo looloo-deploy/helm/looloo \
  --namespace looloo --create-namespace \
  --values looloo-deploy/helm/looloo/values-dev.yaml --take-ownership
kubectl -n looloo rollout status deployment/looloo-kong-gateway
kubectl -n looloo rollout status deployment/looloo-web
```

In development values, Kong forwards `/api/*` to the in-cluster API Service.
The API uses port `30000`, matching the local `.env`. The default chart also
deploys the API inside Kubernetes; configure database URLs reachable from the
pod network for other environments.

The database processes on the host must listen on an address reachable from
Minikube and allow connections from its network. Binding only to host
`127.0.0.1` will not work for pods, even though the connection URL uses
`host.minikube.internal`.

To open the web app locally, keep this command running and visit the printed
local URL (use another free local port if `8080` is occupied):

```bash
kubectl -n looloo port-forward service/looloo-web 18080:80
```

Open `http://localhost:18080`.

For direct gateway testing:

```bash
kubectl -n looloo port-forward service/looloo-kong-gateway 8080:80
```

Then send requests to `http://localhost:8080/api/...`.

## Configure Images

Override image tags through a values file or command-line values. For example:

```bash
helm upgrade --install looloo looloo-deploy/helm/looloo \
  --namespace looloo \
  --set api.image.tag=2.0.1 \
  --set web.image.tag=latest
```

The Kong Admin API is disabled and its Service is internal (`ClusterIP`).
External production access should be configured with TLS and the cluster's
chosen ingress or load-balancing setup.