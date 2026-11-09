#!/usr/bin/env bash
#
# Deploy the Hermes Agent harness on OpenShift, backed by any OpenAI-compatible
# LLM endpoint, with its OpenAI-compatible API ready for Open WebUI.
#
# Re-runnable: a second run updates configuration in place and never rotates
# the API key Open WebUI depends on (unless --rotate-api-key is given).
#
# Every option can also be supplied as an environment variable, which is how
# ../deploy.sh drives this script from a single config file.
#
# Run with --help for usage.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
OVERLAY_DIR="${SCRIPT_DIR}/overlay"
BASE_KUSTOMIZATION="${REPO_ROOT}/gitops/base/kustomization.yaml"

SECRET_NAME="hermes-credentials"
API_PORT=8642

# ---------------------------------------------------------------- defaults --
HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
LLM_BASE_URL="${LLM_BASE_URL:-}"
LLM_MODEL="${LLM_MODEL:-}"
LLM_API_KEY="${LLM_API_KEY:-}"
LLM_API_KEY_FILE="${LLM_API_KEY_FILE:-}"
LLM_NO_API_KEY="${LLM_NO_API_KEY:-false}"
LLM_CONTEXT_LENGTH="${LLM_CONTEXT_LENGTH:-}"
LLM_CA_FILE="${LLM_CA_FILE:-}"
LLM_TRUST_INGRESS_CA="${LLM_TRUST_INGRESS_CA:-false}"
HERMES_STORAGE_CLASS="${HERMES_STORAGE_CLASS:-}"
HERMES_EXPOSE_ROUTE="${HERMES_EXPOSE_ROUTE:-false}"
HERMES_SMOKE_TEST="${HERMES_SMOKE_TEST:-false}"
HERMES_ROTATE_API_KEY="${HERMES_ROTATE_API_KEY:-false}"
HERMES_ROLLOUT_TIMEOUT="${HERMES_ROLLOUT_TIMEOUT:-15m}"
DRY_RUN=false
FORCE=false

# ----------------------------------------------------------------- helpers --
if [[ -t 1 ]]; then
    C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
step() { printf '\n%s==> %s%s\n' "${C_B}" "$*" "${C_0}"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "${C_G}" "${C_0}" "$*"; }
warn() { printf '    %s!%s %s\n' "${C_Y}" "${C_0}" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "${C_R}" "${C_0}" "$*" >&2; exit 1; }

is_true() { [[ "${1,,}" =~ ^(1|true|yes|y|on)$ ]]; }

b64enc() { base64 | tr -d '\n'; }
b64dec() { base64 -d 2>/dev/null || base64 -D; }

# 32 random bytes as hex, without depending on openssl.
random_key() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

# Double-quoted YAML scalar, safe for arbitrary user-supplied strings.
yaml_quote() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# Read one key from a Secret; prints nothing if the Secret or key is absent.
secret_value() {
    local ns=$1 name=$2 key=$3 raw
    raw=$(oc get secret "$name" -n "$ns" -o "jsonpath={.data.${key}}" 2>/dev/null) || return 0
    [[ -n "$raw" ]] && printf '%s' "$raw" | b64dec
    return 0
}

usage() {
    cat <<EOF
${C_B}deploy-hermes.sh${C_0} - deploy the Hermes Agent harness on OpenShift, ready for Open WebUI

${C_B}Usage:${C_0}
  $(basename "$0") --llm-base-url URL --llm-model MODEL [options]

${C_B}LLM backend (any OpenAI-compatible endpoint):${C_0}
  --llm-base-url URL        Endpoint base URL, normally ending in /v1      [LLM_BASE_URL]
                            e.g. https://api.openai.com/v1
                                 https://openrouter.ai/api/v1
                                 http://vllm.models.svc.cluster.local:8000/v1
  --llm-model NAME          Model id exactly as the endpoint's /v1/models
                            reports it                                     [LLM_MODEL]
  --llm-api-key-file FILE   File containing the endpoint's API key         [LLM_API_KEY_FILE]
                            (or export LLM_API_KEY; prompted for if neither
                            is set and a terminal is attached)
  --no-llm-api-key          The endpoint needs no key                      [LLM_NO_API_KEY=true]
  --llm-context-length N    Override the context window Hermes assumes.    [LLM_CONTEXT_LENGTH]
                            Hermes sends ~14k prompt tokens per turn, so
                            the model needs a window of at least 32k.
  --llm-ca-file FILE        Extra PEM CA to trust for the endpoint         [LLM_CA_FILE]
  --trust-ingress-ca        Also trust this cluster's ingress CA (for an
                            endpoint behind a Route with the default
                            self-signed certificate)                       [LLM_TRUST_INGRESS_CA=true]

${C_B}Deployment:${C_0}
  -n, --namespace NS        Namespace (default: hermes)                    [HERMES_NAMESPACE]
  --storage-class SC        StorageClass for the 10Gi state PVC
                            (default: cluster default)                     [HERMES_STORAGE_CLASS]
  --expose-route            Also publish Hermes' API on an external Route.
                            Not needed for Open WebUI, which connects
                            in-cluster.                                    [HERMES_EXPOSE_ROUTE=true]
  --smoke-test              After deploying, run one real agent turn
                            (costs ~14k tokens on your endpoint)           [HERMES_SMOKE_TEST=true]
  --rotate-api-key          Generate a new API_SERVER_KEY. Breaks a
                            connected Open WebUI until it is re-synced.    [HERMES_ROTATE_API_KEY=true]
  --dry-run                 Render the manifests and exit; change nothing
  --force                   Deploy even if Argo CD manages this namespace
  -h, --help                Show this help

${C_B}After it finishes${C_0} it prints the in-cluster URL and Secret Open WebUI needs.
EOF
}

# ---------------------------------------------------------------- arguments --
while [[ $# -gt 0 ]]; do
    case "$1" in
        --llm-base-url)       LLM_BASE_URL=${2:?}; shift 2 ;;
        --llm-model)          LLM_MODEL=${2:?}; shift 2 ;;
        --llm-api-key-file)   LLM_API_KEY_FILE=${2:?}; shift 2 ;;
        --no-llm-api-key)     LLM_NO_API_KEY=true; shift ;;
        --llm-context-length) LLM_CONTEXT_LENGTH=${2:?}; shift 2 ;;
        --llm-ca-file)        LLM_CA_FILE=${2:?}; shift 2 ;;
        --trust-ingress-ca)   LLM_TRUST_INGRESS_CA=true; shift ;;
        -n|--namespace)       HERMES_NAMESPACE=${2:?}; shift 2 ;;
        --storage-class)      HERMES_STORAGE_CLASS=${2:?}; shift 2 ;;
        --expose-route)       HERMES_EXPOSE_ROUTE=true; shift ;;
        --smoke-test)         HERMES_SMOKE_TEST=true; shift ;;
        --rotate-api-key)     HERMES_ROTATE_API_KEY=true; shift ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --force)              FORCE=true; shift ;;
        -h|--help)            usage; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done

NS=$HERMES_NAMESPACE
BUILD_DIR="${SCRIPT_DIR}/.build/${NS}"

# --------------------------------------------------------------- preflight --
step "Preflight"

command -v oc >/dev/null || die "oc not found on PATH"
(( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is required (found ${BASH_VERSION})"

[[ -n "$LLM_BASE_URL" ]] || die "--llm-base-url is required (or set LLM_BASE_URL). See --help."
[[ -n "$LLM_MODEL" ]]    || die "--llm-model is required (or set LLM_MODEL). See --help."
[[ "$LLM_BASE_URL" =~ ^https?:// ]] || die "--llm-base-url must start with http:// or https://"
LLM_BASE_URL=${LLM_BASE_URL%/}
[[ -z "$LLM_CONTEXT_LENGTH" || "$LLM_CONTEXT_LENGTH" =~ ^[0-9]+$ ]] \
    || die "--llm-context-length must be an integer"
if [[ -n "$LLM_CONTEXT_LENGTH" ]] && (( LLM_CONTEXT_LENGTH < 32768 )); then
    warn "context length ${LLM_CONTEXT_LENGTH} is below 32k; Hermes' ~14k-token prompt may not fit"
fi
[[ -z "$LLM_CA_FILE" || -r "$LLM_CA_FILE" ]] || die "cannot read --llm-ca-file ${LLM_CA_FILE}"
if [[ -n "$LLM_CA_FILE" ]] && ! grep -q 'BEGIN CERTIFICATE' "$LLM_CA_FILE"; then
    die "--llm-ca-file ${LLM_CA_FILE} contains no PEM certificate"
fi
[[ "$NS" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "invalid namespace name: ${NS}"

# The overlay pins the Hermes image a second time (see overlay/kustomization.yaml).
# Refuse to deploy two different builds into one pod.
base_digest=$(sed -n 's/^[[:space:]]*digest:[[:space:]]*//p' "$BASE_KUSTOMIZATION" | head -1)
overlay_digest=$(sed -n 's/^[[:space:]]*digest:[[:space:]]*//p' "${OVERLAY_DIR}/kustomization.yaml" | head -1)
[[ -n "$base_digest" && "$base_digest" == "$overlay_digest" ]] || die \
    "image digest mismatch: gitops/base pins ${base_digest:-<none>}, deploy/hermes/overlay pins ${overlay_digest:-<none>}. Update the overlay's images: entry to match."
ok "Hermes image ${base_digest:0:19}… (base and overlay agree)"

if ! $DRY_RUN; then
    oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (oc whoami failed). Run oc login first."
    ok "logged in as $(oc whoami) to $(oc whoami --show-server)"

    # An Argo CD Application with selfHeal would silently revert anything this
    # script changes. Such an Application, for example one left from the earlier
    # gitops/ path, manages Hermes declaratively; don't fight it from here.
    argo_app=$(oc get deploy hermes-agent -n "$NS" \
        -o 'jsonpath={.metadata.labels.argocd\.argoproj\.io/instance}' 2>/dev/null || true)
    if [[ -n "$argo_app" ]] && ! $FORCE; then
        die "namespace ${NS} is managed by Argo CD Application '${argo_app}'. Changes made here would be reverted by its selfHeal. Use a different --namespace, change it through Git, or pass --force."
    fi
fi

# ----------------------------------------------------------- LLM API key ----
# Decide the upstream key without ever putting it on a command line.
existing_llm_key=""
$DRY_RUN || existing_llm_key=$(secret_value "$NS" "$SECRET_NAME" LLM_API_KEY)

if is_true "$LLM_NO_API_KEY"; then
    LLM_API_KEY=""
    llm_key_source="none (endpoint needs no key)"
elif [[ -n "$LLM_API_KEY_FILE" ]]; then
    [[ -r "$LLM_API_KEY_FILE" ]] || die "cannot read --llm-api-key-file ${LLM_API_KEY_FILE}"
    LLM_API_KEY=$(tr -d '\r\n' < "$LLM_API_KEY_FILE")
    [[ -n "$LLM_API_KEY" ]] || die "${LLM_API_KEY_FILE} is empty"
    llm_key_source="file ${LLM_API_KEY_FILE}"
elif [[ -n "$LLM_API_KEY" ]]; then
    llm_key_source="LLM_API_KEY environment variable"
elif [[ -n "$existing_llm_key" ]]; then
    LLM_API_KEY=$existing_llm_key
    llm_key_source="existing Secret ${NS}/${SECRET_NAME} (unchanged)"
elif $DRY_RUN; then
    llm_key_source="(not needed for --dry-run)"
elif [[ -t 0 ]]; then
    read -r -s -p "    API key for ${LLM_BASE_URL} (empty if none): " LLM_API_KEY
    echo
    llm_key_source="interactive prompt"
else
    die "no LLM API key. Use --llm-api-key-file, export LLM_API_KEY, or pass --no-llm-api-key."
fi
ok "LLM key: ${llm_key_source}"

# ------------------------------------------------------ generate overlay ----
step "Generating overlay in ${BUILD_DIR#"${REPO_ROOT}"/}"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Hermes config.yaml. The render-config initContainer copies this onto the PVC
# at every start, so it -- not anything edited inside the pod -- is the source
# of truth for the model binding.
{
    echo "# Generated by deploy-hermes.sh. Rendered onto the state PVC at every pod start."
    echo "model:"
    echo "  # 'custom' = any OpenAI-compatible endpoint. The key arrives as OPENAI_API_KEY."
    echo "  provider: \"custom\""
    echo "  base_url: $(yaml_quote "$LLM_BASE_URL")"
    echo "  default: $(yaml_quote "$LLM_MODEL")"
    [[ -n "$LLM_CONTEXT_LENGTH" ]] && echo "  context_length: ${LLM_CONTEXT_LENGTH}"
    echo "database:"
    echo "  journal_mode: \"wal\""
} > "${BUILD_DIR}/config.yaml"

# Extra CAs to append to the system trust store.
extra_ca=false
: > "${BUILD_DIR}/extra-ca.crt"
if [[ -n "$LLM_CA_FILE" ]]; then
    cat "$LLM_CA_FILE" >> "${BUILD_DIR}/extra-ca.crt"
    extra_ca=true
    ok "trusting extra CA from ${LLM_CA_FILE}"
fi
if is_true "$LLM_TRUST_INGRESS_CA"; then
    $DRY_RUN && die "--trust-ingress-ca needs cluster access; it cannot be combined with --dry-run"
    ingress_ca=$(oc get configmap default-ingress-cert -n openshift-config-managed \
        -o 'jsonpath={.data.ca-bundle\.crt}' 2>/dev/null) \
        || die "cannot read openshift-config-managed/default-ingress-cert (needs cluster-reader)"
    printf '\n%s\n' "$ingress_ca" >> "${BUILD_DIR}/extra-ca.crt"
    extra_ca=true
    ok "trusting the cluster ingress CA"
fi

# PVC storageClassName is immutable, so only set it when creating the PVC.
sc_patch=""
if [[ -n "$HERMES_STORAGE_CLASS" ]]; then
    current_sc=""
    $DRY_RUN || current_sc=$(oc get pvc hermes-data -n "$NS" -o 'jsonpath={.spec.storageClassName}' 2>/dev/null || true)
    if [[ -n "$current_sc" ]]; then
        [[ "$current_sc" == "$HERMES_STORAGE_CLASS" ]] \
            || warn "PVC hermes-data already exists on '${current_sc}'; --storage-class ${HERMES_STORAGE_CLASS} ignored (storageClassName is immutable)"
    else
        sc_patch=$HERMES_STORAGE_CLASS
    fi
fi

{
    echo "# Generated by deploy-hermes.sh for namespace ${NS}. Safe to delete; regenerated each run."
    echo "# Contains no secrets: credentials live in Secret ${NS}/${SECRET_NAME}."
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "namespace: ${NS}"
    echo "resources:"
    echo "  - ../../overlay"
    echo "configMapGenerator:"
    echo "  - name: hermes-model-config"
    echo "    behavior: replace"
    echo "    files:"
    echo "      - config.yaml"
    if $extra_ca; then
        echo "  - name: hermes-extra-ca"
        echo "    files:"
        echo "      - extra-ca.crt"
    fi
    if [[ -n "$sc_patch" ]] || ! is_true "$HERMES_EXPOSE_ROUTE"; then
        echo "patches:"
    fi
    if [[ -n "$sc_patch" ]]; then
        echo "  - patch: |-"
        echo "      apiVersion: v1"
        echo "      kind: PersistentVolumeClaim"
        echo "      metadata:"
        echo "        name: hermes-data"
        echo "      spec:"
        echo "        storageClassName: $(yaml_quote "$sc_patch")"
    fi
    if ! is_true "$HERMES_EXPOSE_ROUTE"; then
        # Open WebUI reaches Hermes over the in-cluster Service, so by default
        # Hermes' API is not published outside the cluster at all.
        echo "  - patch: |-"
        echo "      \$patch: delete"
        echo "      apiVersion: route.openshift.io/v1"
        echo "      kind: Route"
        echo "      metadata:"
        echo "        name: hermes-agent"
    fi
} > "${BUILD_DIR}/kustomization.yaml"

rendered=$(oc kustomize "$BUILD_DIR") || die "kustomize render failed"
ok "rendered $(grep -c '^kind:' <<<"$rendered") resources"

if $DRY_RUN; then
    step "Dry run: manifests that would be applied"
    printf '%s\n' "$rendered"
    exit 0
fi

# --------------------------------------------------------------- namespace --
step "Namespace ${NS}"
if oc get namespace "$NS" >/dev/null 2>&1; then
    ok "exists"
else
    oc create namespace "$NS" --save-config >/dev/null
    ok "created"
fi

# ----------------------------------------------------------------- secret ---
step "Secret ${SECRET_NAME}"

existing_api_key=$(secret_value "$NS" "$SECRET_NAME" API_SERVER_KEY)
if [[ -n "$existing_api_key" ]] && ! is_true "$HERMES_ROTATE_API_KEY"; then
    API_SERVER_KEY=$existing_api_key
    ok "API_SERVER_KEY kept (Open WebUI connections stay valid)"
else
    API_SERVER_KEY=$(random_key)
    if [[ -n "$existing_api_key" ]]; then
        warn "API_SERVER_KEY ROTATED. A connected Open WebUI must be re-synced: re-run its deploy script."
    else
        ok "API_SERVER_KEY generated"
    fi
fi

secret_changed=false
[[ "$LLM_API_KEY" != "$existing_llm_key" ]] && secret_changed=true
[[ "$API_SERVER_KEY" != "$existing_api_key" ]] && secret_changed=true

# Sent to oc on stdin so neither key appears in argv or on disk.
oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: hermes-agent
    app.kubernetes.io/part-of: hermes
  annotations:
    hermes.openshift/managed-by: deploy-hermes.sh
type: Opaque
data:
  API_SERVER_KEY: $(printf '%s' "$API_SERVER_KEY" | b64enc)
  LLM_API_KEY: $(printf '%s' "$LLM_API_KEY" | b64enc)
EOF
ok "applied"

# ------------------------------------------------------------------ apply ---
step "Applying manifests"

deploy_existed=false
oc get deploy hermes-agent -n "$NS" >/dev/null 2>&1 && deploy_existed=true

printf '%s\n' "$rendered" | oc apply -f - | sed 's/^/    /'

# A Route left behind by an earlier --expose-route run is not removed by apply.
if ! is_true "$HERMES_EXPOSE_ROUTE" && oc get route hermes-agent -n "$NS" >/dev/null 2>&1; then
    oc delete route hermes-agent -n "$NS" >/dev/null
    ok "removed external Route (not requested this run)"
fi

# Config changes roll the pod by themselves (hashed ConfigMap names). A changed
# Secret does not -- env from a Secret is read only at container start, so
# without this a rotated key would sit in the Secret while Hermes kept
# honouring the old one.
if $deploy_existed && $secret_changed; then
    oc rollout restart deploy/hermes-agent -n "$NS" >/dev/null
    ok "restarted to pick up the changed credentials"
fi

step "Waiting for Hermes to become ready (first pull of the ~9 GB image can take a few minutes)"
if ! oc rollout status deploy/hermes-agent -n "$NS" --timeout="$HERMES_ROLLOUT_TIMEOUT" | sed 's/^/    /'; then
    warn "rollout did not complete. Recent events:"
    oc get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -10 | sed 's/^/      /' >&2
    die "Hermes is not ready. Inspect with: oc logs deploy/hermes-agent -n ${NS} --all-containers"
fi

# ----------------------------------------------------------------- verify ---
# Everything below runs inside the pod, using the keys already in its
# environment, so no credential ever crosses back to this machine.
step "Verifying"

pod_exec() { oc exec -n "$NS" deploy/hermes-agent -c hermes -- "$@"; }

health=$(pod_exec curl -s -m 10 "http://localhost:${API_PORT}/health" 2>/dev/null || true)
[[ "$health" == *'"ok"'* ]] || die "health check failed: ${health:-no response}"
ok "API server healthy"

models=$(pod_exec sh -c "curl -s -m 10 -H \"Authorization: Bearer \$API_SERVER_KEY\" http://localhost:${API_PORT}/v1/models" 2>/dev/null || true)
[[ "$models" == *'"hermes-agent"'* ]] || die "authenticated /v1/models did not list hermes-agent: ${models:-no response}"
ok "authenticated /v1/models lists 'hermes-agent' (what Open WebUI will see)"

# Reach the upstream LLM from where Hermes actually runs, with its trust bundle
# and key, but without spending an agent turn. Advisory: some servers do not
# implement /models.
upstream=$(pod_exec sh -c '
    code=$(curl -s -m 20 -o /tmp/.llm-models -w "%{http_code}" \
        --cacert "$SSL_CERT_FILE" -H "Authorization: Bearer $OPENAI_API_KEY" "$1/models") || code=000
    printf "%s " "$code"
    grep -qF "\"$2\"" /tmp/.llm-models 2>/dev/null && printf listed || printf unlisted
    rm -f /tmp/.llm-models' _ "$LLM_BASE_URL" "$LLM_MODEL" 2>/dev/null || echo "000 unlisted")
up_code=${upstream%% *}
case "$up_code" in
    200)
        if [[ "$upstream" == *" listed" ]]; then
            ok "LLM endpoint reachable, key accepted, model '${LLM_MODEL}' is listed"
        else
            warn "LLM endpoint reachable and key accepted, but '${LLM_MODEL}' is not in its /models list. Check the model id."
        fi ;;
    401|403) warn "LLM endpoint rejected the key (HTTP ${up_code}). Agent turns will fail until LLM_API_KEY is fixed." ;;
    000)     warn "could not reach ${LLM_BASE_URL} from the pod (DNS, TLS or network). If it uses a private CA, see --llm-ca-file / --trust-ingress-ca." ;;
    *)       warn "LLM endpoint /models returned HTTP ${up_code}; this may be normal for servers that do not implement it." ;;
esac

if is_true "$HERMES_SMOKE_TEST"; then
    info "running one agent turn (this costs tokens)…"
    reply=$(pod_exec sh -c "curl -s -m 300 -X POST http://localhost:${API_PORT}/v1/chat/completions \
        -H \"Authorization: Bearer \$API_SERVER_KEY\" -H 'Content-Type: application/json' \
        -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: HERMES OK\"}]}'" 2>/dev/null || true)
    if [[ "$reply" == *'"choices"'* && "$reply" != *'"failed": true'* ]]; then
        ok "agent turn succeeded"
    else
        warn "agent turn failed: ${reply:0:300}"
    fi
fi

# ---------------------------------------------------------------- summary ---
HERMES_URL="http://hermes-agent.${NS}.svc.cluster.local:${API_PORT}/v1"
step "Hermes is ready for Open WebUI"
cat <<EOF
    In-cluster API URL : ${C_B}${HERMES_URL}${C_0}
    Model id           : hermes-agent
    API key            : Secret ${NS}/${SECRET_NAME}, key API_SERVER_KEY
                         oc get secret ${SECRET_NAME} -n ${NS} -o jsonpath='{.data.API_SERVER_KEY}' | base64 -d
    Backing LLM        : ${LLM_MODEL} @ ${LLM_BASE_URL}
EOF
if is_true "$HERMES_EXPOSE_ROUTE"; then
    host=$(oc get route hermes-agent -n "$NS" -o 'jsonpath={.spec.host}' 2>/dev/null || true)
    [[ -n "$host" ]] && info "External API URL   : https://${host}/v1  (protected only by API_SERVER_KEY)"
fi
cat <<EOF

    Connect Open WebUI:
      ../deploy.sh openwebui                                  (from deploy/hermes/)
      deploy-open-webui.sh --hermes-namespace ${NS}            (standalone)
EOF
