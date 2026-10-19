# Hermes Agent on RHOAI Models-as-a-Service (Argo CD + Kustomize)

Deploys Hermes Agent as a **client of Red Hat OpenShift AI Models-as-a-Service**,
rather than alongside its own vLLM `InferenceService` as [`../manifests/`](../manifests/) does.

MaaS already owns the model, the GPU, the API-key lifecycle and the token quotas,
so this deployment carries none of that. There is no `ServingRuntime`, no
`InferenceService`, no model-weights PVC and no GPU request — Hermes points at
the MaaS gateway over an OpenAI-compatible API and nothing else changes.

Targets **RHOAI 3.5+**, where MaaS is GA.

---

## Why this exists separately from `../manifests/`

The manifests in `../manifests/` match the [Red Hat Developer article][article],
but they do not run against the image that is actually published, and they
predate changes in Hermes itself. Verified against
`quay.io/aicatalyst/hermes-hermes-agent@sha256:1eb7807…`:

| `../manifests/` | Reality |
|---|---|
| `image: quay.io/aicatalyst/hermes-agent:latest` | Does not resolve. The published repository is `hermes-hermes-agent`. |
| `command: ["/opt/hermes/venv/bin/python", …]` | The venv is at `/opt/hermes/.venv`. Overriding `command` also bypasses `entrypoint-openshift.sh`, which activates the venv, builds the state tree and syncs bundled skills. |
| `args: ["gateway"]` | The image already defaults to `CMD ["gateway","run"]`. The bare `gateway` form is no longer a complete command. |
| Port `8080`, probes on `/health` | The API server binds **8642** (`DEFAULT_PORT` in `gateway/platforms/api_server.py`). |
| — | It binds **nothing at all** unless `API_SERVER_ENABLED=true`. Without it the pod starts, never listens, and dies to failing probes with no clear cause. |
| `LLM_MODEL: "hermes-llm"` in a ConfigMap | No longer read. Model, provider and base URL come from `$HERMES_HOME/config.yaml`. |

That last row is the one that shapes this deployment. See
[Why the initContainer](#why-the-initcontainer).

[article]: https://developers.redhat.com/articles/2026/06/02/deploy-hermes-agent-openshift-ai-vllm-model-serving

---

## Layout

```
gitops/
├── base/                     cluster-independent
│   ├── config.yaml           Hermes model config (placeholder; overlay replaces)
│   ├── hermes.env            non-secret env -> ConfigMap hermes-env
│   ├── deployment.yaml       initContainer + agent, no command override
│   ├── namespace.yaml  pvc.yaml  service.yaml  route.yaml
│   └── kustomization.yaml    pins the image by digest
├── overlays/
│   └── rhoai-sandbox3587/    everything cluster-specific lives here
│       ├── config.yaml       real MaaS gateway URL + model name
│       ├── ca-bundle.crt     ingress CA (generated, committed)
│       └── patch-pvc.yaml  patch-route.yaml  kustomization.yaml
├── argocd/
│   └── hermes-agent-application.yaml
└── scripts/
    ├── fetch-ingress-ca.sh        regenerate ca-bundle.crt
    └── bootstrap-credentials.sh   mint MaaS key -> Secret
```

To target another cluster, copy the overlay and change `config.yaml`,
`ca-bundle.crt` and the Route host. The base needs no edits.

---

## Deploy

Two bootstrap steps run before Argo CD, because neither can be expressed in Git.

### 1. Mint the MaaS API key

MaaS keys (`sk-oai-…`) are issued at runtime by `maas-api`. No custom resource
declares one, so nothing committable produces a key. The mint call authenticates
with an **OpenShift bearer token**, not with an `sk-` key:

```
POST {gateway}/maas-api/v1/api-keys      Authorization: Bearer <OpenShift token>
```

```bash
oc login …
./scripts/bootstrap-credentials.sh
```

The mint body must carry a `subscription` — a key does **not** bind to one
implicitly. The script resolves it from `oc get maassubscription -A` and
hard-fails rather than minting a key bound to nothing. It also passes an explicit
`expiresIn` (default 720h, override with `MAAS_KEY_TTL`), because whether
`maas-api` applies a default TTL when the field is omitted is unverified — and
guessing wrong surfaces as a 401 at 3am that looks like a gateway outage.

It verifies the key against `/maas-api/v1/models` before trusting it, then writes
`hermes/hermes-maas-credentials` with:

- `MAAS_API_KEY` — the `sk-` key Hermes sends to MaaS
- `API_SERVER_KEY` — a generated key protecting Hermes' *own* exposed API

Argo CD references this Secret and is configured never to prune or reconcile it.
Re-running the script rotates the key; `--revoke <id>` retires an old one.

> **This flow is a known temporary.** It mints with `oc whoami -t` — a human's
> OpenShift token, which is short-lived and tied to that person's session. If
> they leave, lose the role, or their token is revoked, the `sk-` key may keep
> working while nobody can revoke or re-mint it; an orphaned credential is worse
> than an expired one. The durable shape is a projected ServiceAccount token with
> the pod minting at startup, which also makes rotation automatic because a
> restart re-mints. Whether `maas-api` attributes usage to the minting identity
> is unknown — attribution plausibly hangs off the `MaaSSubscription`, but that
> is unverified.

### 2. Capture the ingress CA

```bash
./scripts/fetch-ingress-ca.sh rhoai-sandbox3587
git commit -am 'Add ingress CA bundle'
```

The MaaS gateway serves the default ingress wildcard certificate, signed by the
ingress operator's own CA. That CA is not publicly trusted, **and the usual
`config.openshift.io/inject-trusted-cabundle` annotation does not help** — it
injects the cluster proxy and system CA bundle, which does not contain it. The
certificate has to be carried explicitly, so the script copies
`openshift-config-managed/default-ingress-cert` into the overlay. It is a public
certificate; committing it is fine. Re-run it after any ingress cert rotation.

### 3. Create the Application

```bash
oc apply -f argocd/hermes-agent-application.yaml
oc get applications.argoproj.io hermes-agent -n openshift-gitops
```

Use the fully-qualified `applications.argoproj.io`. On a cluster running RHACM,
the short name `application` resolves to `app.k8s.io` and silently returns
nothing.

### Verify

```bash
oc get pods -n hermes -w
oc exec deploy/hermes-agent -n hermes -- curl -sS localhost:8642/health

KEY=$(oc get secret hermes-maas-credentials -n hermes \
        -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d)
curl -sS https://hermes.apps.rhoai.sandbox3587.opentlc.com/v1/chat/completions \
  -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hello"}]}'
```

---

## Why the initContainer

Hermes reads its model binding from `$HERMES_HOME/config.yaml`, and
`entrypoint-openshift.sh` seeds that file from a bundled template **only when it
does not already exist**:

```sh
if [ ! -f "$HERMES_HOME/config.yaml" ]; then
    cp "$INSTALL_DIR/cli-config.yaml.example" "$HERMES_HOME/config.yaml"
fi
```

`$HERMES_HOME` is the PVC. So on first boot the agent writes a default config
pointing at OpenRouter, and that file then outlives every redeploy — changes made
in Git would never take effect. Mounting a ConfigMap over `/opt/data` is not an
option either; the whole directory is the agent's read-write state.

The `render-config` initContainer copies the ConfigMap onto the volume on every
start. The config becomes genuinely declarative, and because
`configMapGenerator` appends a content hash to the ConfigMap name, editing
`config.yaml` in Git rolls the pod automatically.

It reuses the Hermes image rather than pulling a second one — the image is ~8.8 GB
and is already on the node.

## How the MaaS binding works

```yaml
model:
  provider: "custom"                     # Hermes' OpenAI-compatible mode
  base_url: "https://maas.…/v1"
  default: "granite-4-tiny-gpu"
  key_env: "MAAS_API_KEY"
```

- **`provider: custom`** is required. Under `openrouter` Hermes prefers
  `OPENROUTER_API_KEY` and will not send the MaaS key to a non-OpenRouter host.
- **`key_env`** is the credential rung Hermes resolves for a bare
  `provider: custom` against a trusted config `base_url`.
- **`default` must be the fully-qualified publisher id**, not the bare model
  name. Verified on this cluster:

  ```
  "publishers/llm/models/granite-4-tiny-gpu"  ->  HTTP 200
  "granite-4-tiny-gpu"                        ->  HTTP 404
  ```

  Routing is **body-based**: the gateway derives
  `X-Gateway-Model-Name: publishers/llm/models/granite-4-tiny-gpu` from the
  request body, and the `HTTPRoute` matches that exact string. A bare name
  matches no rule and falls through to a 404.

  Take the value from the `id` field of `GET {base}/maas-api/v1/models` — not
  from `metadata.name`, and not from `spec.model.name`. Note that a successful
  response then echoes `"model":"granite-4-tiny-gpu"`, the *served* name, so the
  response does not tell you what to send.

## Token quota sizing

Hermes is a poor fit for a small token quota, and this bites immediately.

Measured on this cluster: a single trivial prompt ("reply with three words")
consumed **14,208 prompt tokens**. Hermes front-loads a large system prompt —
tool definitions, skills, memory, `SOUL.md` — on every turn, so that figure is
roughly the *floor* per request, not an outlier. A real multi-turn conversation
with tool calls is several times larger.

The subscription this was tested against allows:

```yaml
tokenRateLimits:
  - limit: 100
    window: 1m
```

100 tokens per minute against a ~14,200-token floor. The first call succeeds on
burst allowance and everything after it returns 429 until the window rolls.

Raising it is a platform decision on the `MaaSSubscription` in the
`models-as-a-service` namespace — deliberately **not** something this
Application touches. And it is not a local change: that subscription's owner is
the group `system:authenticated`, so raising the limit raises it for *every*
caller on the cluster. Giving an agent its own subscription is usually the
better move than widening the shared one.

Budget from measurement, not intuition: multiply the observed per-turn cost by
expected turns per minute, and leave headroom for tool-call loops, which fan out
into several model calls per user message.

Note that a chat-style probe will not reveal this — a smoke test spending ~35
tokens fits the budget comfortably. Only an agent exposes it.

## Deliberate constraints

- **`replicas: 1`, `strategy: Recreate`.** State is SQLite on a ReadWriteOnce
  volume. A rolling update would strand the new pod waiting to attach; a second
  replica would corrupt the database. Scaling out needs RWX or Redis-backed
  state, distributed locking for cron, and session affinity — it is a redesign,
  not a replica count.
- **No `nvidia.com/gpu`.** Inference happens in MaaS. This pod is a client.
- **No `autoshift.io/ai-workload` label** on the namespace. On an AutoShift
  cluster that label selects the model-egress policy, which denies the cloud
  metadata endpoint.
- **The Route is only as safe as `API_SERVER_KEY`.** It publishes Hermes' own
  OpenAI-compatible API and its webhook endpoints. Drop the Route from the
  overlay for cluster-internal use.

## Troubleshooting

| Symptom | Cause |
|---|---|
| **`401` from the agent, but `curl` from inside the same pod with the same key returns `200`** | **The credential never reached Hermes.** `model.key_env` in `config.yaml` is ignored on the bare `provider: custom` path — it is only honoured inside a named `providers:` entry. The key must arrive as the `OPENAI_API_KEY` env var. Listed first because the symptom is actively misleading: it sends you to the certificate and the network, which the working `curl` has already proved fine. |
| `404` on inference while `/v1/models` works fine | Almost always a bare model name in `model.default`. Body-based routing needs the qualified `publishers/<ns>/models/<name>` id. Everything reports `Ready` while this fails. |
| Pod runs, probes fail, no listener | `API_SERVER_ENABLED` not `true`. |
| TLS verify error reaching MaaS | `ca-bundle.crt` is still the placeholder — run `fetch-ingress-ca.sh`. |
| Agent talks to OpenRouter, not MaaS | A stale `config.yaml` on the PVC. Confirm the initContainer ran. |
| `401` from the gateway, `curl` also fails | Key expired, revoked, or minted without a `subscription`. Re-run `bootstrap-credentials.sh`. |
| `429 Too Many Requests` | MaaS token quota. **Expect this with a demo-sized subscription** — see [Token quota](#token-quota-sizing). Not a client bug; raising it is a `MaaSSubscription` change, which is platform-owned. |
| Authenticated request → `no healthy upstream` | Usually `maas-api` itself, not your workload. It holds a PostgreSQL connection to an **external** RDS instance on 5432; a default-deny egress policy on `redhat-ai-gateway-infra` severs it and presents as a gateway fault. |
| `oc get application` returns nothing | RHACM shadows the short name. Use `applications.argoproj.io`. |

## Cluster facts this overlay encodes

| | |
|---|---|
| RHOAI | 3.5.1, DSC `default-dsc` |
| Enablement | `spec.components.aigateway.managementState` **and** `…aigateway.modelsAsAService.managementState`, both `Managed` (the 3.4 `kserve.modelsAsService` field is absent on 3.5+) |
| `maas-api` namespace | `redhat-ai-gateway-infra` (was `redhat-ods-applications` on 3.4) |
| MaaS gateway | `https://maas.apps.rhoai.sandbox3587.opentlc.com` — *not* `rh-ai.apps.…`, which is the dashboard |
| Model | `granite-4-tiny-gpu` (`LLMInferenceService` + `MaaSModelRef` in `llm`) |
| Governance | `MaaSSubscription/granite-4-tiny-gpu-default`, `MaaSAuthPolicy/granite-4-tiny-gpu-access`, both in `models-as-a-service` |
| Storage | `gp3-csi` default, RWO only, single-AZ `us-east-2a` |
| Argo CD | `openshift-gitops`, `default` AppProject |
