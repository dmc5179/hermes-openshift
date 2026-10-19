# Follow-up: mint the MaaS key from a ServiceAccount token, not a human token

**Status:** open, feasibility proven · **Raised:** 2026-10-18 · **Verified
viable:** 2026-10-19 · **Blocks:** nothing today; this ships with the
manual-Secret flow in `scripts/bootstrap-credentials.sh`

> `maas-api` accepts a projected ServiceAccount token, with no RBAC and **no
> audience set** — see [Feasibility](#feasibility-settled-2026-10-19). What
> remains is implementation, not investigation.

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

1. **ServiceAccount, no RBAC.** A bare `hermes-agent` ServiceAccount in the
   `hermes` namespace is sufficient. **Verified** — see
   [Feasibility](#feasibility-settled-2026-10-19): the mint succeeded with zero
   RoleBindings and zero ClusterRoleBindings referencing the account. There is
   no permission scaffolding to design.

2. **Projected token volume — do NOT set an audience.**

   ```yaml
   - serviceAccountToken:
       path: token
       expirationSeconds: 3600
       # No audience. Setting one gets a 401 from maas-api.
   ```

   This is a trap, and it fails in the same misleading way the `key_env` 401
   did: the token is perfectly valid and the API server accepts it, so a 401
   sends you to RBAC or the gateway, and neither is the cause. Measured:
   `oc create token <sa>` → 201, the same command with `--audience=maas` → 401.

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

## Feasibility: settled 2026-10-19

The blocking question — *does `maas-api` accept a projected ServiceAccount token
at all* — is answered: **yes**. Measured against this cluster with a bare
ServiceAccount in a throwaway namespace, using `oc create token`, which is the
same TokenRequest mechanism a projected volume uses:

| Call | Result |
|---|---|
| `POST /maas-api/v1/api-keys` | `201`, returns a normal `sk-oai-` key |
| `GET /maas-api/v1/models` | `200` with that key |
| `POST /v1/chat/completions` | `200`, usage 36/3 |
| `DELETE /maas-api/v1/api-keys/<id>` | `200`, using the SA token |

The full lifecycle works, so the approach is viable rather than speculative.

**Why no RBAC is needed, and why that is not entirely good news.** The
`MaaSSubscription`'s `owner.groups` is `system:authenticated`, and every
ServiceAccount belongs to that group. That is what makes this frictionless — and
it also means *any* ServiceAccount on the cluster can mint a key and spend the
quota. The quota is therefore not meaningfully scoped to Hermes. Narrowing it
means setting `accessGroup` to a real group, which is a platform-side change and
would immediately invalidate existing keys. Fine for a lab; worth knowing before
anyone calls this production-shaped.

### Still unverified

- **Cold-start timing.** Whether `maas-api` answers a mint at pod start when the
  gateway is still coming up on a freshly booted cluster. The initContainer's
  ordering is intra-pod and does not cover this, so the mint wants a retry loop
  with backoff rather than a single attempt.
- **Default TTL** when `expiresIn` is omitted — still unknown, still cheap to
  settle: mint without it, `GET /maas-api/v1/api-keys`, read the expiry, revoke.
  Moot if the mint always passes an explicit short TTL, which it should.
- **Usage attribution** — whether it follows the minting identity or the
  subscription. Less pressing now: the minting identity becomes a ServiceAccount
  rather than a departing human either way.

## Why it isn't built yet

Feasibility is settled but nothing has been implemented here. The remaining work
is ordinary: a ServiceAccount, a projected token volume, a mint initContainer
with retry, and dropping `MAAS_API_KEY` from the bootstrap script.

The manual-Secret flow still works, is documented as a known temporary, and pins
an explicit 720h expiry — so today's failure mode is a loud 401 on a known date,
not a silent orphan. But the main argument for deferring ("it needs live testing
to know if it even works") has now expired.

## Reference

- Mint / list / infer / revoke with exact headers:
  `/home/danclark/workspace/rhoai-mass-aws/scripts/35-smoke-test.sh`
- Platform chain health check: `/home/danclark/workspace/rhoai-mass-aws/scripts/checkup.sh`
