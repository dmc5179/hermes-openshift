#!/usr/bin/env bash
#
# Single entry point: deploy the Hermes Agent harness and Open WebUI on
# OpenShift, together or separately.
#
#   ./deploy.sh all          Hermes, then Open WebUI connected to it
#   ./deploy.sh hermes       Hermes only
#   ./deploy.sh openwebui    Open WebUI only (connects to an existing Hermes)
#   ./deploy.sh status       What is deployed, and is it connected
#   ./deploy.sh mock-llm     A fake LLM endpoint for testing without a model
#   ./deploy.sh undeploy <hermes|openwebui|mock-llm|all> --yes
#
# Configuration comes from an env file (default: ./deploy.env, see
# deploy.env.example) or the environment. Run with --help for details.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
HERMES_SCRIPT="${SCRIPT_DIR}/hermes/deploy-hermes.sh"
MOCK_DIR="${SCRIPT_DIR}/test/mock-llm"

if [[ -t 1 ]]; then
    C_B=$'\033[1m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
    C_B=""; C_G=""; C_Y=""; C_R=""; C_0=""
fi
banner() { printf '\n%s━━━ %s ━━━%s\n' "${C_B}" "$*" "${C_0}"; }
step()   { printf '\n%s==> %s%s\n' "${C_B}" "$*" "${C_0}"; }
ok()     { printf '    %s✓%s %s\n' "${C_G}" "${C_0}" "$*"; }
warn()   { printf '    %s!%s %s\n' "${C_Y}" "${C_0}" "$*" >&2; }
die()    { printf '%sERROR:%s %s\n' "${C_R}" "${C_0}" "$*" >&2; exit 1; }
is_true() { [[ "${1,,}" =~ ^(1|true|yes|y|on)$ ]]; }

usage() {
    cat <<EOF
${C_B}deploy.sh${C_0} - deploy Hermes Agent and Open WebUI on OpenShift

${C_B}Usage:${C_0}
  $(basename "$0") [-c CONFIG] <command> [-- extra options for the component script]

${C_B}Commands:${C_0}
  all                Deploy Hermes, then Open WebUI connected to it
  hermes             Deploy (or update) Hermes only
  openwebui          Deploy (or update) Open WebUI only, connected to Hermes
  status             Show both components and test the connection
  mock-llm           Deploy a fake OpenAI-compatible endpoint for testing
  undeploy TARGET --yes
                     Delete hermes | openwebui | mock-llm | all.
                     Deletes the namespace INCLUDING its persistent data
                     (Hermes' memory and skills, Open WebUI's users and chats).

${C_B}Options:${C_0}
  -c, --config FILE  Env file to load (default: ${SCRIPT_DIR#"${REPO_ROOT}"/}/deploy.env if present)
  -h, --help         Show this help

Anything after "--" is passed to the component script, e.g.
  $(basename "$0") hermes -- --smoke-test
  $(basename "$0") openwebui -- --no-route

Component scripts (each also runs standalone; see their --help):
  Hermes     : ${HERMES_SCRIPT#"${REPO_ROOT}"/}
  Open WebUI : \$OPENWEBUI_DIR/deploy-open-webui.sh
               (default OPENWEBUI_DIR: ${REPO_ROOT}/../../open-web-ui)
EOF
}

# ---------------------------------------------------------------- arguments --
CONFIG_FILE=""
COMMAND=""
TARGET=""
CONFIRM=false
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE=${2:?}; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        --yes)       CONFIRM=true; shift ;;
        --)          shift; PASSTHROUGH=("$@"); break ;;
        all|hermes|openwebui|status|mock-llm|undeploy)
            if [[ -z "$COMMAND" ]]; then COMMAND=$1
            elif [[ "$COMMAND" == undeploy && -z "$TARGET" ]]; then TARGET=$1
            else die "unexpected argument: $1"; fi
            shift ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done
[[ -n "$COMMAND" ]] || { usage; exit 1; }

# ------------------------------------------------------------------ config --
if [[ -z "$CONFIG_FILE" && -f "${SCRIPT_DIR}/deploy.env" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/deploy.env"
fi
if [[ -n "$CONFIG_FILE" ]]; then
    [[ -r "$CONFIG_FILE" ]] || die "cannot read config file ${CONFIG_FILE}"
    # Export everything it sets so the component scripts inherit it.
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a
    printf '%sconfig:%s %s\n' "${C_B}" "${C_0}" "$CONFIG_FILE"
fi

export HERMES_NAMESPACE="${HERMES_NAMESPACE:-hermes}"
export OPENWEBUI_NAMESPACE="${OPENWEBUI_NAMESPACE:-open-webui}"
MOCK_NAMESPACE=mock-llm
OPENWEBUI_DIR="${OPENWEBUI_DIR:-${REPO_ROOT}/../../open-web-ui}"
OPENWEBUI_SCRIPT="${OPENWEBUI_DIR}/deploy-open-webui.sh"

command -v oc >/dev/null || die "oc not found on PATH"
(( BASH_VERSINFO[0] >= 4 )) || die "bash 4 or newer is required (found ${BASH_VERSION})"

require_login() {
    oc whoami >/dev/null 2>&1 || die "not logged in to a cluster (oc whoami failed). Run oc login first."
}
require_openwebui_script() {
    [[ -x "$OPENWEBUI_SCRIPT" ]] || die "Open WebUI script not found at ${OPENWEBUI_SCRIPT}. Set OPENWEBUI_DIR to the directory containing deploy-open-webui.sh."
}

# --------------------------------------------------------------- mock-llm ---
deploy_mock() {
    banner "Mock LLM (testing only)"
    require_login
    step "Namespace and key"
    oc get namespace "$MOCK_NAMESPACE" >/dev/null 2>&1 || oc create namespace "$MOCK_NAMESPACE" --save-config >/dev/null
    local key raw
    # Absent on first run. The || true matters: under set -e + pipefail a
    # failing lookup would otherwise end the script without a word.
    raw=$(oc get secret mock-llm-key -n "$MOCK_NAMESPACE" -o 'jsonpath={.data.MOCK_API_KEY}' 2>/dev/null || true)
    key=""
    [[ -n "$raw" ]] && key=$(printf '%s' "$raw" | { base64 -d 2>/dev/null || base64 -D; })
    if [[ -z "$key" ]]; then
        key=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
        oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: mock-llm-key
  namespace: ${MOCK_NAMESPACE}
type: Opaque
data:
  MOCK_API_KEY: $(printf '%s' "$key" | base64 | tr -d '\n')
EOF
        ok "API key generated (Secret ${MOCK_NAMESPACE}/mock-llm-key)"
    else
        ok "API key kept"
    fi
    step "Applying"
    oc apply -k "$MOCK_DIR" | sed 's/^/    /'
    oc rollout status deploy/mock-llm -n "$MOCK_NAMESPACE" --timeout=5m | sed 's/^/    /'

    # Feed the next step (hermes) when invoked as part of `all`.
    export LLM_BASE_URL="http://mock-llm.${MOCK_NAMESPACE}.svc.cluster.local:8000/v1"
    export LLM_MODEL=mock-model
    export LLM_API_KEY=$key
    export LLM_CONTEXT_LENGTH=131072
    # The mock's key must win over any key source left in the config file.
    export LLM_API_KEY_FILE="" LLM_NO_API_KEY=false LLM_CA_FILE="" LLM_TRUST_INGRESS_CA=false
    ok "endpoint ${LLM_BASE_URL}, model ${LLM_MODEL}"
    if [[ "$COMMAND" == mock-llm ]]; then
        cat <<EOF

    Point Hermes at it with these settings (or set LLM_MOCK=true in deploy.env):
      LLM_BASE_URL=${LLM_BASE_URL}
      LLM_MODEL=${LLM_MODEL}
      LLM_CONTEXT_LENGTH=${LLM_CONTEXT_LENGTH}
      LLM_API_KEY=\$(oc get secret mock-llm-key -n ${MOCK_NAMESPACE} -o jsonpath='{.data.MOCK_API_KEY}' | base64 -d)
EOF
    fi
}

deploy_hermes() {
    banner "Hermes Agent"
    if is_true "${LLM_MOCK:-false}"; then
        deploy_mock
        banner "Hermes Agent"
    fi
    "$HERMES_SCRIPT" "$@"
}

deploy_openwebui() {
    require_openwebui_script
    banner "Open WebUI"
    "$OPENWEBUI_SCRIPT" "$@"
}

# ----------------------------------------------------------------- status ---
show_status() {
    require_login
    banner "Status ($(oc whoami --show-server))"
    local ns label
    for pair in "Hermes:${HERMES_NAMESPACE}" "Open WebUI:${OPENWEBUI_NAMESPACE}" "Mock LLM:${MOCK_NAMESPACE}"; do
        label=${pair%%:*}; ns=${pair#*:}
        step "${label} (namespace ${ns})"
        if ! oc get namespace "$ns" >/dev/null 2>&1; then
            printf '    not deployed\n'; continue
        fi
        oc get deploy,pvc -n "$ns" --no-headers 2>/dev/null | sed 's/^/    /' || true
        oc get route -n "$ns" -o 'custom-columns=ROUTE:.metadata.name,URL:.spec.host' --no-headers 2>/dev/null \
            | awk '{print "    route " $1 ": https://" $2}' || true
    done

    step "Connection Open WebUI -> Hermes"
    if ! oc get deploy open-webui -n "$OPENWEBUI_NAMESPACE" >/dev/null 2>&1; then
        printf '    Open WebUI not deployed\n'; return 0
    fi
    local cm url models
    # The ConfigMap the Deployment actually uses -- older hashed copies from
    # previous runs may still exist alongside it.
    cm=$(oc get deploy open-webui -n "$OPENWEBUI_NAMESPACE" \
        -o 'jsonpath={.spec.template.spec.containers[0].envFrom[0].configMapRef.name}' 2>/dev/null || true)
    url=$(oc get configmap "$cm" -n "$OPENWEBUI_NAMESPACE" -o 'jsonpath={.data.OPENAI_API_BASE_URL}' 2>/dev/null || true)

    # 1. Network path and the key in the running pod.
    models=$(oc exec -n "$OPENWEBUI_NAMESPACE" deploy/open-webui -c open-webui -- \
        sh -c 'curl -s -m 15 -H "Authorization: Bearer $OPENAI_API_KEY" "$1/models"' _ "$url" 2>/dev/null || true)
    if [[ "$models" == *'"hermes-agent"'* ]]; then
        ok "reachable: ${url} lists 'hermes-agent' with the pod's key"
    else
        warn "not reachable: ${url:-<unknown URL>} -> ${models:-no response}"
    fi

    # 2. The key Open WebUI actually uses lives in its database, which can lag
    # behind the pod (it ignores the env after first start). Compare the
    # fingerprint recorded for the database against Hermes' current key.
    local hermes_key="" s recorded current
    for s in hermes-credentials hermes-maas-credentials; do
        hermes_key=$(oc get secret "$s" -n "$HERMES_NAMESPACE" -o 'jsonpath={.data.API_SERVER_KEY}' 2>/dev/null || true)
        [[ -n "$hermes_key" ]] && break
    done
    recorded=$(oc get secret open-webui-secrets -n "$OPENWEBUI_NAMESPACE" \
        -o 'jsonpath={.metadata.annotations.openwebui\.hermes/connection-fingerprint}' 2>/dev/null || true)
    if [[ -z "$hermes_key" || -z "$recorded" ]]; then
        warn "cannot compare Open WebUI's stored connection with Hermes (Hermes key or fingerprint not found)"
    else
        hermes_key=$(printf '%s' "$hermes_key" | { base64 -d 2>/dev/null || base64 -D; })
        if command -v sha256sum >/dev/null; then
            current=$(printf '%s\n%s' "$url" "$hermes_key" | sha256sum | cut -d' ' -f1)
        else
            current=$(printf '%s\n%s' "$url" "$hermes_key" | shasum -a 256 | cut -d' ' -f1)
        fi
        if [[ "$recorded" == "$current" ]]; then
            ok "in sync: Open WebUI's stored connection matches Hermes' current URL and key"
        else
            warn "OUT OF DATE: Open WebUI's stored connection does not match Hermes' current key."
            warn "Users will see 'Model not found'. Fix: ./deploy.sh openwebui (with admin credentials in the config)"
        fi
    fi
}

# --------------------------------------------------------------- undeploy ---
undeploy() {
    local target=$1
    [[ "$target" =~ ^(hermes|openwebui|mock-llm|all)$ ]] || die "undeploy needs a target: hermes | openwebui | mock-llm | all"
    local -a namespaces=()
    case "$target" in
        hermes)    namespaces=("$HERMES_NAMESPACE") ;;
        openwebui) namespaces=("$OPENWEBUI_NAMESPACE") ;;
        mock-llm)  namespaces=("$MOCK_NAMESPACE") ;;
        all)       namespaces=("$OPENWEBUI_NAMESPACE" "$HERMES_NAMESPACE" "$MOCK_NAMESPACE") ;;
    esac
    $CONFIRM || die "undeploy deletes namespace(s) ${namespaces[*]} and ALL their persistent data. Re-run with --yes to confirm."
    require_login
    local ns argo
    for ns in "${namespaces[@]}"; do
        if ! oc get namespace "$ns" >/dev/null 2>&1; then
            ok "${ns}: not present"; continue
        fi
        argo=$(oc get deploy -n "$ns" -o 'jsonpath={.items[*].metadata.labels.argocd\.argoproj\.io/instance}' 2>/dev/null || true)
        if [[ -n "$argo" ]]; then
            warn "${ns}: managed by Argo CD Application '${argo%% *}'; skipping. Remove it through Argo CD."
            continue
        fi
        oc delete namespace "$ns" --wait=false >/dev/null
        ok "${ns}: deletion started"
    done
}

# -------------------------------------------------------------------- run ---
case "$COMMAND" in
    all)
        require_openwebui_script
        deploy_hermes
        deploy_openwebui
        banner "Done"
        printf '    Hermes     : http://hermes-agent.%s.svc.cluster.local:8642/v1\n' "$HERMES_NAMESPACE"
        host=$(oc get route open-webui -n "$OPENWEBUI_NAMESPACE" -o 'jsonpath={.spec.host}' 2>/dev/null || true)
        [[ -n "$host" ]] && printf '    Open WebUI : %shttps://%s%s\n' "${C_B}" "$host" "${C_0}"
        ;;
    hermes)    deploy_hermes ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"} ;;
    openwebui) deploy_openwebui ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"} ;;
    mock-llm)  deploy_mock ;;
    status)    show_status ;;
    undeploy)  undeploy "${TARGET:-}" ;;
esac
