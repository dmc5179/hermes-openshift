#!/usr/bin/env bash
# Copy the cluster's ingress CA into an overlay so Hermes can verify the MaaS
# gateway's TLS certificate.
#
# Why this is needed: the MaaS gateway serves the default ingress wildcard cert,
# signed by the ingress operator's own CA. That CA is not publicly trusted, and
# it is NOT part of what config.openshift.io/inject-trusted-cabundle injects --
# that annotation gives you the cluster proxy plus system CA bundle, which does
# not include it. The certificate has to be carried explicitly.
#
# The output is a public certificate, not a secret. Commit it.
#
# Usage:  ./gitops/scripts/fetch-ingress-ca.sh [overlay-name]

set -euo pipefail

OVERLAY="${1:-rhoai-sandbox3587}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEST="${SCRIPT_DIR}/../overlays/${OVERLAY}/ca-bundle.crt"

if [[ ! -d "$(dirname -- "${DEST}")" ]]; then
    echo "error: overlay '${OVERLAY}' not found at $(dirname -- "${DEST}")" >&2
    exit 1
fi

echo "Reading openshift-config-managed/default-ingress-cert ..."
oc get configmap default-ingress-cert \
    -n openshift-config-managed \
    -o jsonpath='{.data.ca-bundle\.crt}' > "${DEST}"

if [[ ! -s "${DEST}" ]]; then
    echo "error: wrote an empty bundle to ${DEST}" >&2
    exit 1
fi

echo "Wrote ${DEST}"
echo
echo "Certificates in bundle:"
openssl crl2pkcs7 -nocrl -certfile "${DEST}" \
    | openssl pkcs7 -print_certs -noout 2>/dev/null \
    || echo "  (install openssl to list them)"

echo
echo "Commit this file, then let Argo CD sync."
