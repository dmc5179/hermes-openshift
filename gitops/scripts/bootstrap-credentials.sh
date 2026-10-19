#!/usr/bin/env bash
# Mint a MaaS API key and create the Secret that Argo CD expects to already exist.
#
# This is the one step that cannot be GitOps'd. MaaS API keys (sk-oai-...) are
# issued at runtime by maas-api; there is no custom resource that declares one,
# so nothing can be committed to Git that produces a key. Argo CD references the
# resulting Secret by name and otherwise leaves it alone.
#
# The mint call authenticates with an OpenShift bearer token -- NOT with an
# sk- key. Only inference and the management reads use the sk- key.
#
# Re-running this rotates the key: a new one is minted and the Secret is updated.
# The old key keeps working until you revoke it (see --revoke below).
#
# KNOWN TEMPORARY -- read before relying on this in anger.
# The mint authenticates with `oc whoami -t`, a human's OpenShift token. That is
# right for a smoke test and wrong for a 24/7 workload: the user token is
# short-lived and tied to that person's session, so if they leave, lose the role,
# or their token is revoked, the sk- key may keep working while nobody can revoke
# or re-mint it. An orphaned credential is worse than an expired one.
#
# The durable shape is a projected ServiceAccount token, minting at pod startup --
# which also solves rotation for free, because a restart re-mints. That is a
# change in deployment design, so it is called out rather than done silently.
#
# Usage:
#   ./gitops/scripts/bootstrap-credentials.sh
#   ./gitops/scripts/bootstrap-credentials.sh --revoke <key-id>

set -euo pipefail

NAMESPACE="${HERMES_NAMESPACE:-hermes}"
SECRET_NAME="hermes-maas-credentials"
MAAS_BASE="${MAAS_BASE:-https://maas.apps.rhoai.sandbox3587.opentlc.com}"

# Always sent explicitly. Whether maas-api applies a default TTL when expiresIn
# is omitted is NOT verified -- it may issue a key that lives until revoked, or
# one that quietly expires. Guessing wrong surfaces as a 401 at 3am that looks
# like a gateway outage, so the lifetime is pinned here and rotation is a
# deliberate act (re-run this script).
KEY_TTL="${MAAS_KEY_TTL:-720h}"

require() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 not found" >&2; exit 1; }; }
require oc
require curl
require jq

TOKEN="$(oc whoami -t)"
[[ -n "${TOKEN}" ]] || { echo "error: not logged in (oc whoami -t returned nothing)" >&2; exit 1; }

# --- revoke mode -------------------------------------------------------------
if [[ "${1:-}" == "--revoke" ]]; then
    KEY_ID="${2:?usage: $0 --revoke <key-id>}"
    curl -sS -k -X DELETE "${MAAS_BASE}/maas-api/v1/api-keys/${KEY_ID}" \
        -H "Authorization: Bearer ${TOKEN}"
    echo "Revoked ${KEY_ID}"
    exit 0
fi

# --- resolve the subscription -------------------------------------------------
# `subscription` is REQUIRED in the mint body on this platform; the key does not
# bind to a subscription implicitly. Omitting it has not been tested -- it may
# 400, or it may hand back a key bound to nothing, which half-works and fails
# confusingly later. So resolve it and hard-fail if it is missing.
#
# The MaaSSubscription lives in namespace models-as-a-service while the model
# lives in llm; only the bare name is passed.
SUBSCRIPTION="${MAAS_SUBSCRIPTION:-$(oc get maassubscription -A \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)}"

if [[ -z "${SUBSCRIPTION}" ]]; then
    echo "error: no MaaSSubscription found and MAAS_SUBSCRIPTION not set." >&2
    echo "       Minting without one is not safe to assume. List them with:" >&2
    echo "         oc get maassubscription -A" >&2
    exit 1
fi
echo "Using MaaSSubscription: ${SUBSCRIPTION}"

# --- mint --------------------------------------------------------------------
# -k because the gateway uses the self-signed ingress cert and this script runs
# from a workstation that has not trusted it. The Hermes pod does NOT skip
# verification: it gets the real CA bundle via fetch-ingress-ca.sh.
echo "Minting a MaaS API key at ${MAAS_BASE} (expiresIn=${KEY_TTL}) ..."
RESPONSE="$(curl -sS -k -X POST "${MAAS_BASE}/maas-api/v1/api-keys" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
            --arg name "hermes-agent" \
            --arg description "Hermes Agent gateway (gitops/scripts/bootstrap-credentials.sh)" \
            --arg expiresIn "${KEY_TTL}" \
            --arg subscription "${SUBSCRIPTION}" \
            '{name: $name, description: $description,
              expiresIn: $expiresIn, subscription: $subscription}')")"

API_KEY="$(jq -r '.key // empty' <<<"${RESPONSE}")"
KEY_ID="$(jq -r '.id // empty' <<<"${RESPONSE}")"

if [[ -z "${API_KEY}" ]]; then
    echo "error: no key in response. Raw response:" >&2
    jq . <<<"${RESPONSE}" >&2 || echo "${RESPONSE}" >&2
    exit 1
fi

case "${API_KEY}" in
    sk-*) ;;
    *) echo "warning: key does not start with sk- ; inference endpoints may reject it" >&2 ;;
esac

# Verify the key actually works before writing it into the cluster.
echo "Verifying the key against ${MAAS_BASE}/maas-api/v1/models ..."
if ! curl -sS -k -f "${MAAS_BASE}/maas-api/v1/models" \
        -H "Authorization: Bearer ${API_KEY}" >/dev/null; then
    echo "error: minted key was rejected by /maas-api/v1/models" >&2
    exit 1
fi

# API_SERVER_KEY protects Hermes' OWN exposed API (the Route), and is unrelated
# to MaaS. Generated here so the Route is never left unauthenticated.
API_SERVER_KEY="$(openssl rand -hex 32)"

oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f - >/dev/null

oc create secret generic "${SECRET_NAME}" \
    --namespace "${NAMESPACE}" \
    --from-literal=MAAS_API_KEY="${API_KEY}" \
    --from-literal=API_SERVER_KEY="${API_SERVER_KEY}" \
    --dry-run=client -o yaml | oc apply -f -

# Keep Argo CD from pruning or reporting drift on a Secret it does not own.
oc label secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    app.kubernetes.io/part-of=hermes --overwrite >/dev/null
oc annotate secret "${SECRET_NAME}" -n "${NAMESPACE}" \
    argocd.argoproj.io/sync-options=Prune=false --overwrite >/dev/null

echo
echo "Secret ${NAMESPACE}/${SECRET_NAME} is in place."
echo "  Subscription: ${SUBSCRIPTION}"
echo "  Expires in  : ${KEY_TTL}  -- re-run this script to rotate before then"
echo "  MaaS key id : ${KEY_ID:-<not returned>}   (revoke with: $0 --revoke ${KEY_ID:-<id>})"
echo "  Route key   : read it back with"
echo "                oc get secret ${SECRET_NAME} -n ${NAMESPACE} -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d"
