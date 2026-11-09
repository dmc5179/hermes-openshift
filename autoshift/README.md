# Hermes Agent and Open WebUI as AutoShift policies

On clusters with Red Hat OpenShift AI Models-as-a-Service and Red Hat Advanced Cluster
Management, Hermes and Open WebUI are deployed by two AutoShift policies, not from this
repository. The policies live in the AutoShift fork:

| | |
|---|---|
| Repository | `dmc5179/autoshiftv2`, branch `rhoai-maas` |
| Policies | `policies/stable/hermes-agent/`, `policies/stable/open-webui/` |
| Documentation | the `README.md` in each policy directory: configuration, policies, behavior |
| Enable on a cluster | labels `hermes-agent` and `open-webui`, plus `config.hermesAgent.model`, in the cluster's values |

They follow the same model as the rest of AutoShift: Argo CD on the hub delivers the policies,
and RHACM applies the resources to each cluster selected by its labels. Hermes is the
counterpart of [`../deploy/`](../deploy/) (any cluster, any OpenAI-compatible endpoint) and of
[`../gitops/`](../gitops/) (the findings from the earlier Argo CD path for MaaS, since removed).

## What the policies do

- **Hermes** derives its model id, Models-as-a-Service subscription, gateway and CA from
  `config.openshiftAiModels` and the managed cluster, so only the model name is configured.
- **Hermes mints its own MaaS key** with its ServiceAccount, keeps it with its expiry in a Secret,
  and renews it by restarting itself shortly before it expires. It generates the API key Open
  WebUI uses. No credential comes from git or from a person.
- **Open WebUI** connects to Hermes in the cluster and copies that API key. With
  `openWebui.auth: openshift`, users sign in with OpenShift credentials through an oauth-proxy
  sidecar, limited to `allowedGroups` (default `maas-users`).
- **Inform policies** report Models-as-a-Service access, readiness, the health of the key, and
  each workload's state.

## History

Drafted in this repository and applied to the fork:

| Fork commit | Change |
|---|---|
| `adbc6a9b` | The `hermes-agent` and `open-webui` policies |
| `9e338e6c` | Self-renewing MaaS key; Open WebUI sign-in through OpenShift |
| `f9e97ca8` | The key check waits for the pod to be Available |

Each was validated before handoff: the fork's `make test` passed with no skipped template blocks,
a deliberate defect in each new manifest failed the suite (proving the policies were rendered),
and Vale reported no errors. New logic was also exercised on its own: the bootstrap against mocks
of the Kubernetes and MaaS APIs, and the Open WebUI sign-in settings in the real image.

Verified live on sandbox141 (OpenShift 4.22, RHOAI 3.5.2, RHACM 2.17), with every policy
Compliant:

- an agent turn through the Open WebUI Route to Granite on Models-as-a-Service, including a real
  tool call, confirmed in Hermes' session store;
- the MaaS key minted, stored and scheduled for renewal;
- OpenShift sign-in admitting a `maas-users` member as administrator and refusing a non-member.
