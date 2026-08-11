# Plan: a denied query should say so, not return zero rows

**Status.** Backlog — filed 2026-08-11 from a live observation.

## What happens

A read model or state-view slice carrying
`@@reventless.authorize(AllowGroups(["Admin"]))` is queried by a caller outside
the group. The resolver evaluates the rule, takes the `Deny` branch, and returns
an **empty connection** — `edges: []`, `pageInfo` with no next page
(`reventless/local/src/adapter/QueryDb/QueryDbResolvers_GraphQL.res:350`, and the
same shape at `:252` for the by-ids field and `:390` for the scan field). No
error, no extension code, HTTP 200.

Observed against the hybrid example: an operator-only customer list returns two
rows for an admin token and `{"edges":[]}` for a shopper token. The two responses
are indistinguishable from "this view is empty".

## Why it is worth changing

**The same framework already answers the other half honestly.** A denied
*mutation* returns `CommandRejected` with `errorCode: "Forbidden"` and a detail
naming the field. A denied *query* returns success. One of the two is wrong, and
it is not the mutation.

**Zero is a claim, and this makes the system state it falsely.** A client cannot
distinguish "you may not read this" from "there is nothing here", so it renders a
confident empty state — an empty table with no explanation is read by users as a
fact about the data. The same failure mode has already been paid for once in the
UI seam that dropped GraphQL `errors` from a successful fetch.

**It gets worse the moment reads are scoped by owner.** When a query resolver
narrows rows to the caller's own, "empty" becomes a *legitimate and common*
answer. A denial that is also spelled "empty" is then unfalsifiable from the
outside: nobody can tell a misconfigured rule from a customer with no orders, and
the misconfiguration survives every test that asserts on rows.

**No information is protected by the silence.** The field is in the published
schema either way; refusing it by name discloses nothing a caller cannot already
see by introspection.

## Options

1. **Return a GraphQL error**, mirroring the mutation path — `Forbidden`, with
   the field name in the message and a code in `extensions`. Consistent with the
   mutation half and with what the admin queries already do
   (`Unauthorized: requires group "Admin"`).
2. **Keep the empty payload, log at WARN.** Cheapest, and still leaves every
   client unable to tell the two cases apart. Only defensible if some deployment
   is known to depend on the empty shape.
3. **Empty payload plus a typed marker on the connection** (e.g. a `refused`
   flag). Avoids breaking callers that treat any error as fatal, at the cost of a
   contract change every consumer must learn.

Recommendation: option 1. It is the shape the rest of the framework already uses,
and the migration risk is a caller that today silently renders nothing — which is
the behaviour this plan exists to stop.

## Care needed

- **Both transports, one change.** The AWS query path must be audited for the
  same branch and land in the same version. Drift between local and deployed
  authorization behaviour is a known failure mode, and the deployed half is the
  one nobody runs by hand.
- The admin/platform queries already refuse loudly; whatever shape is chosen here
  should match theirs rather than invent a third.
- Check the console's own queries before flipping: a surface that currently
  queries something it is not entitled to would go from a quiet empty panel to a
  visible error, which is the point, but it should be a known list rather than a
  discovery.
