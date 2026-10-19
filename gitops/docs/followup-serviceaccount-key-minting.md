# Follow-up: mint the MaaS key from a ServiceAccount token, not a human token

**Status:** open · **Raised:** 2026-10-18 · **Blocks:** nothing today; this ships
with the manual-Secret flow in `scripts/bootstrap-credentials.sh`

## The problem

`bootstrap-credentials.sh` mints the MaaS API key with `oc whoami -t` — the
operator's own OpenShift token. That is right for a smoke test and wrong for a
workload that runs continuously.

An OpenShift user token is short-lived and bound to that person's session. The
`sk-` key it produces is not. So the two can decouple:

- The person leaves, loses the role, or their token is revoked.
- The `sk-` key keeps working — Hermes keeps serving.
- Nobody can revoke it or mint a replacement, because both operations
  authenticate with an OpenShift token that no longer exists.

That is an **orphaned credential**, and it is a harder problem than an expired
one. An expired key fails loudly and someone fixes it. An orphaned key works
until it doesn't, and at that point the person who could have rotated it is gone.

Secondary, and genuinely unknown: whether `maas-api` records the minting identity
for usage attribution. Attribution plausibly hangs off the `MaaSSubscription`,
which is the rate-limit and quota unit — but that has not been verified against
the `maas-api` source or the docs. If it does attribute to the minter, a
departed employee's name is on the traffic.

## The shape of the fix

Give the workload its own identity and let it mint for itself at startup.

```
ServiceAccount hermes-agent
  └── projected token (audience-scoped, auto-rotated by kubelet)
        └── initContainer: POST /maas-api/v1/api-keys  with that token
              └── sk- key written to an emptyDir shared with the agent
```

A pod restart re-mints, so rotation stops being a calendar reminder and becomes
a property of the system. The key can then carry a *short* `expiresIn` — hours,
not the current 720h — which shrinks the blast radius of a leak.

### Pieces

1. **ServiceAccount + RBAC.** `hermes-agent` in the `hermes` namespace, with
   whatever role `maas-api` requires of a mint caller. Determining that is the
   first unknown: the API authorises an OpenShift bearer token, but which
   permission it checks is not documented in what we've read.

2. **Projected token volume**, with the audience `maas-api` expects. If it
   accepts the default API-server audience this is trivial; if it wants a custom
   one, the audience has to be discovered.

3. **A mint initContainer** replacing the static Secret. It writes the `sk-` key
   to a shared `emptyDir`, and Hermes reads it via `key_env` pointing at a file,
   or the initContainer writes a small env file the agent sources. Hermes'
   `key_env` resolves an *environment variable*, so this needs either a wrapper
   that exports it, or a Secret written by the initContainer via the API.

4. **Revocation on shutdown** (optional). A `preStop` hook that DELETEs the key
   keeps the key list from accumulating dead entries. Best-effort — a hard pod
   kill skips it, so the short `expiresIn` is what actually bounds the mess.

5. **Drop `MAAS_API_KEY`** from `hermes-maas-credentials`. The Secret still holds
   `API_SERVER_KEY`, which protects Hermes' own Route and is unrelated to MaaS.

## Open questions to settle first

- Does `maas-api` accept a projected ServiceAccount token at all, or does it
  require a token with a user identity? **This is the question that decides
  whether the whole approach works** — settle it before building anything else.
- What audience must the projected token carry?
- What RBAC does the mint call check?
- Does usage attribution follow the minting identity or the `MaaSSubscription`?
- Does `maas-api` apply a default TTL when `expiresIn` is omitted? Cheap
  read-only experiment: mint without it, `GET /maas-api/v1/api-keys`, inspect the
  expiry field, revoke.

## Why it isn't being done now

It is a change in deployment design, not a bug fix, and it needs live testing
against `maas-api` to answer the questions above. The manual-Secret flow works,
is documented as a known temporary, and pins an explicit 720h expiry — so the
failure mode today is a loud 401 on a known date, not a silent orphan.

Worth doing before this is anything more than a demo.

## Reference

- Mint / list / infer / revoke with exact headers:
  `/home/danclark/workspace/rhoai-mass-aws/scripts/35-smoke-test.sh`
- Platform chain health check: `/home/danclark/workspace/rhoai-mass-aws/scripts/checkup.sh`
