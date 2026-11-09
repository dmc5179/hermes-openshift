# Deploy Hermes Agent + Open WebUI on OpenShift

One entry point to deploy the [Hermes Agent](https://github.com/NousResearch/hermes-agent)
harness and [Open WebUI](https://github.com/open-webui/open-webui) on OpenShift,
connected to each other. You can deploy both together or each one on its own.

```
 browser ──HTTPS──▶ Route ──▶ Open WebUI ──in-cluster──▶ Hermes Agent ──▶ your LLM
                              (namespace                (namespace        (any OpenAI-
                               open-webui)               hermes)           compatible API)
```

- **Hermes** is the agent: tools, persistent memory, skills it learns, cron.
  It exposes an OpenAI-compatible API on port 8642 and does its thinking with
  whatever LLM you point it at.
- **Open WebUI** is the chat UI. It handles users, chat history and file
  upload, and shows Hermes as a single model called `hermes-agent`.

Hermes' API is **not** published outside the cluster by default. Open WebUI
reaches it over the cluster network, using a key the scripts generate and wire
up for you.

---

## Quick start

You need `oc` logged in to an OpenShift 4 cluster, bash 4+, and an
OpenAI-compatible LLM endpoint.

```bash
cd deploy
cp deploy.env.example deploy.env
$EDITOR deploy.env          # set LLM_BASE_URL, LLM_MODEL, LLM_API_KEY_FILE,
                            # and ideally OPENWEBUI_ADMIN_EMAIL + password file
./deploy.sh all
```

It ends by printing the Open WebUI URL. Log in and start chatting. `hermes-agent`
is already selected. On a fresh cluster the whole run takes about **3½ minutes**,
mostly the first pull of the ~9 GB Hermes image. A re-run with nothing to change
takes seconds.

**No model yet?** Set `LLM_MOCK=true` in `deploy.env`. That deploys a tiny fake
OpenAI-compatible endpoint and points Hermes at it, so you can prove the whole
chain works before you involve a real (or paid) model. See [Testing without a model](#testing-without-a-model).

---

## Commands

| Command | What it does |
|---|---|
| `./deploy.sh all` | Deploy Hermes, then Open WebUI connected to it |
| `./deploy.sh hermes` | Deploy or update Hermes only |
| `./deploy.sh openwebui` | Deploy or update Open WebUI only; finds Hermes and its key automatically |
| `./deploy.sh status` | Show what's deployed and test the Open WebUI → Hermes connection |
| `./deploy.sh mock-llm` | Deploy only the fake LLM endpoint |
| `./deploy.sh undeploy <hermes\|openwebui\|mock-llm\|all> --yes` | Delete the namespace(s), **including their data** |

Use `-c FILE` to choose a config file other than `./deploy.env`. To pass extra
flags to one component, put them after `--`:

```bash
./deploy.sh hermes -- --smoke-test          # also run one real agent turn
./deploy.sh openwebui -- --no-route         # no public URL; use port-forward
```

Every command is **safe to re-run**. A second run updates configuration in
place. It does not rotate keys, recreate accounts or wipe data.

### Deploying separately

Each component has its own script, and you can run it without `deploy.sh`:

| Component | Script | Help |
|---|---|---|
| Hermes | [`hermes/deploy-hermes.sh`](hermes/deploy-hermes.sh) | `--help` |
| Open WebUI | `<workspace>/open-web-ui/deploy-open-webui.sh` | `--help` |

```bash
# Hermes on its own
./hermes/deploy-hermes.sh --llm-base-url https://api.openai.com/v1 \
    --llm-model gpt-4.1 --llm-api-key-file ~/.secrets/openai

# Open WebUI later, or by someone else, against that Hermes
../../../open-web-ui/deploy-open-webui.sh --hermes-namespace hermes \
    --admin-email you@example.com --admin-password-file ~/.secrets/owui-admin
```

Open WebUI can also point at a Hermes that wasn't deployed by these scripts.
Pass `--hermes-url` and `--hermes-api-key-file`. It also recognizes the RHOAI
MaaS deployment from the historical [`../gitops/`](../gitops/) path automatically.

`deploy.sh` looks for the Open WebUI script in `<workspace>/open-web-ui`, the
directory two levels above this repo. Set `OPENWEBUI_DIR` if yours is
elsewhere.

---

## Configuration

Everything lives in `deploy.env`. Start from [`deploy.env.example`](deploy.env.example),
which documents every setting. The essentials:

| Setting | Meaning |
|---|---|
| `LLM_BASE_URL` | Your endpoint, normally ending in `/v1` (OpenAI, OpenRouter, vLLM, NIM, …) |
| `LLM_MODEL` | Model id exactly as the endpoint's `/v1/models` reports it |
| `LLM_API_KEY_FILE` | File holding the endpoint's key (or `LLM_API_KEY`, or `LLM_NO_API_KEY=true`) |
| `OPENWEBUI_ADMIN_EMAIL` + `OPENWEBUI_ADMIN_PASSWORD_FILE` | Creates the admin account **before** the site goes public |
| `HERMES_NAMESPACE` / `OPENWEBUI_NAMESPACE` | Default `hermes` / `open-webui` |

**Choosing a model.** Hermes sends about **14,000 prompt tokens on every
turn**: its tools, skills and memory travel with each request. The model needs
a context window of at least 32k, it should support tool calling, and you
should budget for the cost. A trivial "hello" through Hermes costs as much as
a page of text.

**Private CAs.** If the endpoint uses a certificate from a private CA, set
`LLM_CA_FILE`. If it sits behind an OpenShift Route with the cluster's default
self-signed certificate, set `LLM_TRUST_INGRESS_CA=true`. Public CAs are always
trusted.

**Secrets never touch disk.** Keys are read from files or the environment and
sent to `oc` on stdin. The generated overlays under `.build/` contain no
credentials.

---

## What the scripts create

**Hermes** (namespace `hermes`):

| Object | Purpose |
|---|---|
| Deployment `hermes-agent` | 1 replica (state is SQLite on an RWO volume) |
| PVC `hermes-data` (10Gi) | Everything Hermes learns: memory, skills, conversation history |
| Service `hermes-agent:8642` | The OpenAI-compatible API Open WebUI connects to |
| Secret `hermes-credentials` | `API_SERVER_KEY` (Open WebUI → Hermes), `LLM_API_KEY` (Hermes → LLM) |
| ConfigMaps | Model config, env, trust-bundle extras |

**Open WebUI** (namespace `open-webui`):

| Object | Purpose |
|---|---|
| Deployment `open-webui` | 1 replica |
| PVC `open-webui-data` (10Gi) | Users, chats, settings, uploads, vector store |
| Service + Route | Public HTTPS URL (edge TLS, 10-minute timeout for long agent turns) |
| Secret `open-webui-secrets` | Session-signing key, and Hermes' API key |

Both workloads run under the default `restricted-v2` SCC. Neither needs
privileged access, a custom SCC or a GPU.

### Reuse of the existing Hermes work

The Hermes Deployment isn't a second copy. [`hermes/overlay/`](hermes/overlay/)
layers onto the verified [`../gitops/base`](../gitops/base) and swaps out only
the parts specific to RHOAI MaaS: the key-minting entrypoint, the MaaS
credentials and the MaaS CA. So every fix that base carries applies here too:
the 8642 port and `API_SERVER_ENABLED`, config rendered onto the PVC at each
start, `Prune=false` protection of the data volume, and the pinned image. The
`gitops/` tree is untouched. The script refuses to modify a namespace that an
Argo CD Application manages.

---

## Things worth knowing

**All Open WebUI users share one Hermes.** Every user talks to the same agent.
It shares the agent's learned skills, its built-in memory (`MEMORY.md`,
`USER.md`) and its searchable history. Open WebUI sends a per-user
`X-Hermes-Session-Key`, but Hermes only uses that in its optional Honcho memory
provider. Treat this as a team sharing one assistant. For isolation between
teams, deploy one Hermes per team, each in its own namespace.

**Open WebUI's background tasks are off.** By default Open WebUI also asks the
chat model to write a title, tags and follow-up suggestions for every message.
Against Hermes, each of those is a full ~14k-token agent turn, and Hermes treats
it as a real request: it may act on it and will remember it. So title, tag,
follow-up, search-query and retrieval-query generation are disabled. Re-enable
them in **Admin Panel → Settings → Interface** only if you set a separate plain
LLM as the task model.

**Open WebUI settings apply on first start only.** Open WebUI copies most
environment settings into its database the first time it starts, including the
Hermes URL and key, and ignores the environment after that. That's why the
scripts never rotate Hermes' key on their own.

If the URL or key does change (`--rotate-api-key`, or Hermes redeployed from
scratch), users see an empty model list and `Model not found`. Re-run
`./deploy.sh openwebui` to fix it:

- **With admin credentials in `deploy.env`**, the script updates the stored
  connection itself, through the same admin API the Admin Panel uses.
- **Without them**, it prints the exact **Admin Panel → Settings → Connections**
  change to make. Re-run with `-- --connection-fixed` afterwards to acknowledge it.

`./deploy.sh status` reports whether the stored connection is **in sync** with
Hermes' current key.

**Long agent turns are normal.** Hermes may run several tools before it
answers. The Open WebUI Route allows 10 minutes; Hermes streams its progress
meanwhile.

**Deleting is destructive.** `undeploy` deletes namespaces, and with them
Hermes' accumulated memory and skills and Open WebUI's users and chats. It
requires `--yes`.

---

## Testing without a model

`LLM_MOCK=true` (or `./deploy.sh mock-llm`) deploys [`test/mock-llm`](test/mock-llm/),
about 150 lines of standard-library Python on a stock UBI image. It speaks
enough of the OpenAI API (`/v1/models`, streaming and non-streaming
`/v1/chat/completions`) and **enforces a bearer key** to exercise every hop:

- Open WebUI → Hermes: network path and `API_SERVER_KEY`
- Hermes → LLM: URL, `LLM_API_KEY` and trust bundle
- streaming through both

Ask it `Reply with exactly: hello` and it answers `hello`. Anything else gets
an echo. It isn't a model, so expect agent behaviour to be trivial, but if the
mock works end to end, switching to a real endpoint is only a change to the
`LLM_*` settings.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Empty model dropdown, or `Model not found` | Open WebUI's stored connection is out of date, usually after Hermes' key changed. `./deploy.sh status` says **OUT OF DATE**. Fix: `./deploy.sh openwebui`; see *settings apply on first start only* above. |
| Chat returns an error mentioning 401 | Hermes' upstream LLM key is wrong. The Hermes script's verification step reports this directly. Re-run with the right `LLM_API_KEY_FILE`. |
| Chat hangs or errors on long tasks | A proxy between you and the cluster with a shorter timeout than the Route's 10 minutes. |
| Hermes pod stuck in `Init` for minutes | First pull of the ~9 GB Hermes image. Subsequent restarts are fast. |
| Open WebUI uploads or RAG fail | The models weren't seeded: check `oc logs deploy/open-webui -c seed-models -n open-webui`. |
| `managed by Argo CD Application` | An Argo CD Application manages that namespace, for example one left from the historical [`../gitops/`](../gitops/) path. Use another `HERMES_NAMESPACE`, or change it through Git. |

Logs: `oc logs deploy/hermes-agent -n hermes --all-containers` and
`oc logs deploy/open-webui -n open-webui --all-containers`.
