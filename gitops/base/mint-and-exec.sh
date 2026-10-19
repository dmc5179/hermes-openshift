#!/usr/bin/env bash
#
# Mint a MaaS API key with this pod's ServiceAccount token, put it in the
# environment, and hand off to the image's real entrypoint.
#
# WHY A WRAPPER AND NOT AN initContainer
# Hermes reads its credential from the OPENAI_API_KEY environment variable
# (model.key_env in config.yaml is ignored on the bare `provider: custom` path).
# Environment variables are resolved by the kubelet before the main container
# starts, so an initContainer that mints a key cannot get it into the running
# process: writing a file is useless because the app wants a variable, and
# writing a Secret is useless because the env was already resolved from it --
# that approach is permanently one restart behind. Setting the variable in the
# process and exec'ing the real entrypoint is the only path that works.
#
# WHY THE TTL IS LONG
# This pins the key into the process environment for the pod's entire life. A
# running process cannot have its environment changed from outside, so the key
# cannot be refreshed in place: expiresIn must exceed the maximum pod lifetime,
# NOT the expected restart interval. A short TTL on a long-lived pod expires
# mid-life, Hermes starts returning 401 from its model, and no probe calls that
# unhealthy -- it looks exactly like a MaaS outage. "A restart re-mints" is not
# a substitute for a sufficient TTL.
#
# What self-minting actually buys is no human in the loop, therefore no
# credential orphaned when a person's token dies, and a ServiceAccount identity
# the platform can scope its quota to.

set -euo pipefail

TOKEN_PATH=/var/run/secrets/kubernetes.io/serviceaccount/token

MAAS_API_BASE="${MAAS_API_BASE:?MAAS_API_BASE must be set (gateway base URL, no /v1 suffix)}"
MAAS_SUBSCRIPTION="${MAAS_SUBSCRIPTION:?MAAS_SUBSCRIPTION must be set (MaaSSubscription name)}"
MAAS_KEY_TTL="${MAAS_KEY_TTL:-720h}"
MINT_ATTEMPTS="${MAAS_MINT_ATTEMPTS:-10}"

log() { printf '[mint] %s\n' "$*" >&2; }

# Everything below must never print the key. Responses are parsed, not echoed.

curl_args=(--silent --show-error --max-time 30)
if [[ -n "${SSL_CERT_FILE:-}" && -r "${SSL_CERT_FILE}" ]]; then
    curl_args+=(--cacert "${SSL_CERT_FILE}")
else
    log "WARNING: SSL_CERT_FILE unset or unreadable; TLS verification uses the system store"
fi

body="$(python3 -c '
import json, os, sys
json.dump({
    "name": os.environ.get("MAAS_KEY_NAME", "hermes-agent"),
    "description": "Self-minted at pod start by gitops/base/mint-and-exec.sh",
    "expiresIn": os.environ["MAAS_KEY_TTL"],
    "subscription": os.environ["MAAS_SUBSCRIPTION"],
}, sys.stdout)
')"

# Retry, because on a cold cluster the gateway may not be serving yet when this
# pod starts. Backoff is linear and bounded; the pod fails rather than starting
# without a key, since a keyless Hermes presents as a model fault rather than a
# startup fault and is correspondingly hard to diagnose.
api_key=""
for attempt in $(seq 1 "${MINT_ATTEMPTS}"); do
    # Re-read the token each attempt: it is kubelet-rotated and a long backoff
    # could outlive the copy we read first time round.
    token="$(cat "${TOKEN_PATH}")"

    http_code=0
    response=""
    if response="$(curl "${curl_args[@]}" \
            --write-out '\n%{http_code}' \
            -X POST "${MAAS_API_BASE}/maas-api/v1/api-keys" \
            -H "Authorization: Bearer ${token}" \
            -H 'Content-Type: application/json' \
            -d "${body}" 2>/dev/null)"; then
        http_code="$(printf '%s' "${response}" | tail -n1)"
        response="$(printf '%s' "${response}" | sed '$d')"
    fi

    if [[ "${http_code}" == "200" || "${http_code}" == "201" ]]; then
        api_key="$(printf '%s' "${response}" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("key", ""))
except Exception:
    print("")
')"
        if [[ -n "${api_key}" ]]; then
            key_id="$(printf '%s' "${response}" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("id", "<none>"))
except Exception:
    print("<none>")
')"
            log "minted key id=${key_id} ttl=${MAAS_KEY_TTL} subscription=${MAAS_SUBSCRIPTION}"
            break
        fi
        log "attempt ${attempt}/${MINT_ATTEMPTS}: HTTP ${http_code} but no key in response"
    elif [[ "${http_code}" == "0" ]]; then
        # curl never got an HTTP response at all. Distinguished from a real
        # status because "HTTP 0" reads like a server reply and sends people
        # looking at the gateway, when the cause is DNS, TLS or connectivity --
        # which on a cold cluster is the expected transient this retry exists
        # for.
        log "attempt ${attempt}/${MINT_ATTEMPTS}: no HTTP response (DNS, TLS or connection failure reaching ${MAAS_API_BASE})"
    else
        log "attempt ${attempt}/${MINT_ATTEMPTS}: mint rejected, HTTP ${http_code}"
    fi

    if (( attempt < MINT_ATTEMPTS )); then
        sleep $(( attempt < 6 ? attempt * 5 : 30 ))
    fi
done

if [[ -z "${api_key}" ]]; then
    log "FATAL: could not mint a MaaS API key after ${MINT_ATTEMPTS} attempts."
    log "  gateway      ${MAAS_API_BASE}"
    log "  subscription ${MAAS_SUBSCRIPTION}"
    log "  Exiting rather than starting without a key. A keyless Hermes answers"
    log "  401 from its model, which looks like a MaaS outage rather than a"
    log "  startup failure. Check that the subscription exists and that this"
    log "  ServiceAccount is in its owner.groups."
    exit 1
fi

export OPENAI_API_KEY="${api_key}"
unset api_key token response body

# Hand off to the image's own entrypoint. Overriding `command` replaces both
# ENTRYPOINT and CMD, so both halves are reproduced here:
#   ENTRYPOINT ["/usr/local/bin/tini","-g","--","/opt/hermes/docker/entrypoint-openshift.sh"]
#   CMD        ["gateway","run"]
# exec so tini becomes PID 1 and keeps its signal handling and reaping.
log "handing off to the Hermes entrypoint"
exec /usr/local/bin/tini -g -- /opt/hermes/docker/entrypoint-openshift.sh "$@"
