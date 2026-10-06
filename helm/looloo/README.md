# Looloo Helm Chart

This chart deploys the Looloo API, chatbot API, web app, and DB-less Kong Gateway into one
namespace. Web requests under `/api/` and `/chatbot-api/` go through Kong,
which strips each prefix before forwarding to the corresponding API.

## Deploy to Minikube

From the workspace root, `./looloo-deploy/scripts/start-app.sh` starts the app
and prints its localhost URL. Use `./looloo-deploy/scripts/start.sh` to start
both the app and monitoring. Run `./looloo-deploy/scripts/stop.sh` to stop the
app workloads and their helper processes.

After the app is running, use `./looloo-deploy/scripts/refresh.sh` to rebuild
and reload the API, chatbot API, and web images, apply current secrets and Helm
settings, and roll out the app deployments. It keeps the existing localhost
port-forward URL and does not stop Minikube or monitoring.

For local testing, `start-app.sh` builds the chatbot API image, loads it into
Minikube, creates its Secret from `chatbot-api/.env`, and waits for its
Deployment. Create that file from `chatbot-api/.env.example`; its
`JWT_SECRET_KEY` must match `looloo-api/.env`. The helper routes database and
Ollama connections through its host relay and points Kong's `/chatbot-api/`
route at the in-cluster chatbot API Service.

For a manual Helm deploy, provide `chatbot-api-env` and `looloo-api-env`
Kubernetes Secrets and set the chatbot API image values. To build/load the app
images and install the chart's development values from the workspace root:

```bash
cd looloo-api && docker build -f Dockerfile.production -t looloo-api:minikube .
cd ../chatbot-api && docker build -t chatbot-api:minikube .
cd ../looloo-web && docker build -f Dockerfile.production -t looloo-web:minikube .
cd ..
minikube image load looloo-api:minikube
minikube image load chatbot-api:minikube
minikube image load looloo-web:minikube
cd looloo-api && npm run k8s:secrets && cd ..
helm upgrade --install looloo looloo-deploy/helm/looloo \
  --namespace looloo --create-namespace \
  --values looloo-deploy/helm/looloo/values-dev.yaml --take-ownership
kubectl -n looloo rollout status deployment/looloo-kong-gateway
kubectl -n looloo rollout status deployment/looloo-web
```

In development values, Kong forwards `/api/*` to the in-cluster API Service.
The Looloo API uses port `30000`, matching its local `.env`; chatbot-api uses
port `3001`. Configure database and Ollama URLs reachable from the pod network
for other environments.

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
Assistant requests use `http://localhost:8080/chatbot-api/...`.

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
