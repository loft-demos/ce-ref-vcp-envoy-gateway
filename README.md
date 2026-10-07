# ce-ref-vcp-envoy-gateway

Expose vCluster Platform through [Envoy Gateway](https://gateway.envoyproxy.io/)
with the Kubernetes Gateway API, including tenant clusters that use **private
nodes**.

An ordinary HTTPRoute gets you the vCluster Platform UI and API. Private nodes
fail to join unless you also allow the HTTP upgrade types they use, because
Envoy Gateway accepts only `websocket` by default. This repo has the complete
set of objects: one route, one upgrade policy, and optional CORS, with TLS
terminated once at Envoy.

```text
                         :80  http listener  --> 301 to https
client --DNS--> LB IP -->
                         :443 https listener --> HTTPRoute vcluster-platform --> Service loft:80
                              (TLS terminate)    + BackendTrafficPolicy  (upgrade types)
                                                 + SecurityPolicy        (CORS, optional)
```

Tested with:

| Component | Version |
| --- | --- |
| Envoy Gateway | v1.9.2 (Envoy 1.39), Gateway API v1.6.1 CRDs |
| vCluster Platform | 4.13.0-alpha.19 |
| Kubernetes | v1.36 |
| cert-manager | v1.20 |

## What is in here

```text
manifests/                    kubectl apply -k manifests/
  gatewayclass.yaml           "eg" GatewayClass for the Envoy Gateway controller
  envoyproxy.yaml             Envoy data plane: 2 replicas, LoadBalancer Service
  certificate.yaml            cert-manager Certificate for the Platform hostname
  gateway.yaml                listeners: http (redirect) and https (terminate)
  platform-routes.yaml        redirect route, and the route to the loft Service
  platform-upgrades.yaml      the upgrade types vCluster Platform needs
optional/
  platform-cors.yaml          CORS, only if a browser page on another origin calls the API
values/
  vcluster-platform.yaml      Helm values: chart ingress off, loftHost set
hack/
  check.sh                    end-to-end checks, including the upgrade probes
```

## Why the upgrade policy matters

vCluster Platform serves everything on one hostname (`config.loftHost`): the
UI, the API, the Kubernetes proxy to tenant clusters, and, for private nodes,
an embedded Tailscale coordinator and DERP relay. Several of those switch
protocols with an HTTP/1.1 `Upgrade`:

| Upgrade type | Used by |
| --- | --- |
| `websocket` | UI; `kubectl exec`/`attach` on newer clients; DERP from websocket-built Tailscale clients |
| `spdy/3.1` | `kubectl exec`/`port-forward` on older clients |
| `tailscale-control-protocol` | Private nodes registering: `POST /ts2021` (also served at `/coordinator/ts2021`) |
| `DERP` | Private nodes' DERP relay from standard Tailscale clients: `GET /derp` |

Envoy accepts an upgrade only if its type is on an allowlist, and Envoy
Gateway's default list is `websocket` alone. Anything else gets a local `403`
from Envoy, with `upgrade_failed` in the access log, and never reaches vCluster
Platform. The symptoms:

- Private nodes stay logged out (`NeedsLogin`) and never get a Tailscale IP.
- `GET /derp/probe` and `GET /coordinator/key` succeed (they're plain requests),
  so the edge looks healthy.

`platform-upgrades.yaml` (`BackendTrafficPolicy.spec.httpUpgrade`) adds the
missing types for the Platform route only. The list replaces the default, so
`websocket` is listed explicitly. Don't add `requestBuffer` to that policy:
when it's set, Envoy Gateway ignores the upgrade configuration.

The route also sets `timeouts.request: 0s`. Envoy's default route timeout is
15s, which would cut off watches, log follows, and the Tailscale map poll.

## Install

### 1. Envoy Gateway

```sh
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.9.2 \
  --namespace envoy-gateway-system --create-namespace
```

The chart installs the Gateway API CRDs (experimental channel) and the Envoy
Gateway CRDs.

### 2. Set your hostname and issuer

```sh
grep -rl platform.example.com manifests values optional \
  | xargs sed -i.bak 's/platform\.example\.com/vcp.your-domain.com/g'
find . -name '*.bak' -delete
```

In `manifests/certificate.yaml`, set `issuerRef` to your cert-manager
ClusterIssuer:

- **Edge reachable from the internet:** HTTP-01 works.
- **Public DNS pointing at a private IP:** use DNS-01, because Let's Encrypt
  can't reach the edge.
- **No cert-manager:** delete `certificate.yaml` and create a
  `kubernetes.io/tls` Secret named `platform-tls` in `envoy-gateway-system`.

Private nodes have to trust this certificate, so use a public CA unless you
distribute a private one to them.

In `manifests/envoyproxy.yaml`, add any annotations your load balancer needs,
for example a fixed address.

### 3. vCluster Platform

```sh
helm upgrade --install vcluster-platform vcluster-platform \
  --repo https://charts.loft.sh \
  --namespace vcluster-platform --create-namespace \
  -f values/vcluster-platform.yaml
```

`ingress.enabled: false` turns off the chart's ingress; the Gateway takes its
place. If vCluster Platform is already installed, only `config.loftHost` has to
match the Gateway hostname.

The routes and the Gateway's `allowedRoutes` assume the `vcluster-platform`
namespace. If you installed elsewhere, change both.

### 4. The edge

```sh
kubectl apply -k manifests/
```

Point DNS for the hostname at the Envoy Service's external address:

```sh
kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=platform-edge
```

### 5. Check it

```sh
PLATFORM_HOST=vcp.your-domain.com hack/check.sh
```

The script checks that the routes and policy are Accepted, `/version` works,
port 80 redirects, and every upgrade type reaches vCluster Platform:

- **Tailscale upgrade:** a handshake-less probe should get `400 missing
  Tailscale handshake header` from vCluster Platform. A `403` with an empty
  body means Envoy blocked the upgrade type.
- **DERP and websocket upgrades:** each should get `101`.

Add `CORS_ORIGIN=https://...` to also check the optional CORS policy.

For a live picture of private-node sessions, read Envoy's upgrade gauge.
Upgraded connections appear in the access log only when they close, so a
healthy node is otherwise invisible there:

```sh
kubectl -n envoy-gateway-system port-forward <envoy-pod> 19000:19000 &
curl -s 'http://127.0.0.1:19000/stats?filter=upgrades_active'
```

## CORS (optional)

Only needed when a browser page on another origin calls the vCluster Platform
API with an `Authorization` header, for example a status or wake page served on
a tenant cluster's hostname. The browser sends a preflight for that request.
vCluster Platform sets no CORS headers of its own, and it strips any it gets
from backends, so the edge is the only place they can come from.

Edit the origins in `optional/platform-cors.yaml`, then
`kubectl apply -f optional/platform-cors.yaml`. How it behaves:

- **Preflights from allowed origins:** Envoy answers them without forwarding.
- **Allowed requests:** Envoy echoes the origin in
  `Access-Control-Allow-Origin`.
- **Other origins:** no allow header, so the browser blocks the response.
- **Clients without an `Origin` header** (kubectl, private nodes): unaffected.

Rules for the policy:

- **`allowOrigins` format:** strings. A wildcard covers one leading label, and
  the scheme is required.
- **`allowCredentials`:** leave it unset when the page sends a bearer token in a
  header rather than cookies.
- **Attach point:** the Platform route, not the Gateway. A route-level
  SecurityPolicy replaces a Gateway-level one, and at Gateway level CORS would
  apply to every route on it.

## Sleep mode and HTTPRoute activity

vCluster Platform's sleep mode can count HTTP traffic through an HTTPRoute as
activity. To do that it adds a request-mirror filter to the route, and only if
the route's GatewayClass supports mirroring. Envoy Gateway supports the filter,
but doesn't advertise `HTTPRouteRequestMirror` in the GatewayClass status. So
on every control plane cluster that runs Envoy Gateway, annotate the vCluster
Platform `Cluster` resource:

```sh
kubectl annotate clusters.management.loft.sh <cluster-name> \
  sleepmode.loft.sh/request-mirror-controller-allowlist=gateway.envoyproxy.io/gatewayclass-controller
```

The value is a comma-separated list of `GatewayClass.spec.controllerName`
values.

Without the annotation:

- Tenant clusters hosted on that cluster show an Info condition,
  `NoSupportedGatewayClass` ("No installed GatewayClass advertises
  HTTPRouteRequestMirror support...").
- Traffic through their HTTPRoutes doesn't refresh the last-activity timestamp,
  so a tenant cluster can go to sleep while its app is in use.

The condition is recomputed from the cluster's GatewayClasses, so there's no
way to hide it. Setting the annotation clears it. Only list controllers that
really support the request-mirror filter: vCluster Platform then adds that
filter to routes on those classes.

## Sharing the Gateway

You can serve other hostnames from the same Gateway, such as tenant cluster
apps synced with vCluster's Gateway API sync, or admin tools. Add a listener per
hostname or wildcard and widen its `allowedRoutes`.

**Pin every route to a listener with `sectionName`.** Envoy Gateway merges all
port-80 listeners into one Envoy route configuration. Gateway API wildcards
match any number of labels, so `*.example.com` also matches
`app.tenant.example.com`. Suppose a route has no `sectionName`, and its hostname
matches two port-80 listeners (say `*.example.com` and `*.tenant.example.com`):

- The route attaches to both, and the merged config lists its domain twice.
- Envoy rejects that config with `Duplicate entry of domain`.
- The pod keeps serving its last good config, so nothing breaks yet.
- After the Envoy pod restarts, port-80 routing for the whole Gateway is gone.

For routes created inside tenant clusters, set `sectionName` in the app's chart
or template. vCluster passes it through when it syncs the route to the control
plane cluster.

**Don't give the Platform hostname two listeners on the same port.** If a
wildcard listener's certificate also covers the Platform hostname, browsers may
reuse an HTTP/2 connection opened for another host on that listener. Keep
vCluster Platform on its own listener, as here, or on the wildcard listener with
its route, but not both.

## Operations

- **Certificate renewal:** Envoy Gateway watches the TLS Secret and pushes
  renewals to Envoy over SDS. No restarts.
- **Upgrading Envoy Gateway:** read the release notes for Gateway API CRD
  changes. The CRDs include a "safe-upgrades" admission policy that blocks
  downgrading them, so rolling back Envoy Gateway can mean handling the CRDs by
  hand. New Envoy versions roll the data-plane pods. See the rollout-strategy
  comment in `envoyproxy.yaml` if you use required anti-affinity.
- **Client IP:** with `externalTrafficPolicy: Cluster`, vCluster Platform sees a
  node IP in `X-Forwarded-For`. Set `externalTrafficPolicy: Local` on the
  EnvoyProxy Service if you need real client IPs in vCluster Platform audit
  logs, and make sure your load balancer only targets nodes running Envoy.
- **GitOps on the same Gateway:** if your Argo CD or Git server is served
  through this Gateway, a bad edge change also cuts off the tool that would fix
  it. Mark the GatewayClass, EnvoyProxy, and Gateway with
  `argocd.argoproj.io/sync-options: Prune=false,Delete=false`, and keep a
  checkout from which you can run `kubectl apply -k manifests/` by hand.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| Private nodes stuck in `NeedsLogin`; Envoy log shows `POST /ts2021 403 upgrade_failed` on `:443` | Upgrade policy missing, not Accepted, or targeting the wrong route |
| `POST /ts2021 403 upgrade_failed` with `:authority <host>:80` | Expected. The Tailscale client tries ports 80 and 443 at once; the port 80 attempt hits the redirect route and loses |
| `GET /derp` gets `403` | `DERP` missing from the upgrade list |
| Watches or `kubectl logs -f` through vCluster Platform drop after 15s | `timeouts.request: 0s` missing on the route |
| Idle streams drop after a few minutes | Raise the stream idle timeout with a ClientTrafficPolicy (`timeout.http.idleTimeout`) on the `https` listener |
| Browser console shows a CORS error | Origin not in `allowOrigins`, the scheme is missing, or the policy targets the Gateway instead of the route |
| Envoy log: `Duplicate entry of domain` | A route without `sectionName` matched two listeners on one port. See [Sharing the Gateway](#sharing-the-gateway) |

## Other edges

The same requirements apply to any edge in front of vCluster Platform:

- HTTP/1.1 upgrades: `websocket` and `spdy/3.1`, plus `tailscale-control-protocol`
  and `DERP` with private nodes
- no short request timeout or response buffering
- `Host` and `X-Forwarded-Proto: https` forwarded
- no small request-body limit
- CORS only for cross-origin browser pages

| Edge | Notes |
| --- | --- |
| ingress-nginx (the vCluster Platform chart's default ingress) | Forwards any `Upgrade`. Raise `proxy-read-timeout`, `proxy-send-timeout`, and `proxy-body-size` with annotations. |
| Other Envoy-based Gateway API implementations | Expect the same websocket-only default until tested. Find the implementation's upgrade-type setting and run `hack/check.sh`. |
| Envoy Gateway without `httpUpgrade` (older releases) | Add the upgrade types to the HTTP connection manager's `upgrade_configs` with an `EnvoyPatchPolicy`. Check with `kubectl explain backendtrafficpolicy.spec.httpUpgrade`. |
| L4 load balancer straight to vCluster Platform | vCluster Platform terminates TLS and handles every upgrade itself. It serves a custom certificate from `PROXY_TLS_CERT`/`PROXY_TLS_KEY` (chart `envValueFrom` with a `secretKeyRef`), read only at startup, so restart it after renewal. There's no place to add CORS. |
