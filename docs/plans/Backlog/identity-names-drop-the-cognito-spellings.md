# Plan: the platform stops publishing and reading the old `cognito*` names

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/active-role-store-scoped-to-the-pool.md](../done/active-role-store-scoped-to-the-pool.md) when it closed. Waits on a fact outside this repo: no pinned consumer may still read the old names, and the `IDENTITY_PROVIDER_ID` secret must be confirmed present in every deploying repo.<br/>
**Relates to:** [../identity-is-a-capability-not-a-cognito-handle.md](../identity-is-a-capability-not-a-cognito-handle.md); reventless-ui's `shell-reads-identity-provider-keys.md` owns the shell's half (steps 7.2 and 7.4 of the parent).

---

## In plain words

The platform renamed its identity settings from Cognito-specific names
(`cognitoUserPoolId`, …) to neutral ones (`identityProviderId`, …). To avoid a
flag day it publishes and reads **both** spellings. This note is the clean-up:
removing the old spellings once nothing depends on them any more.

## What is left

1. **Old stack exports** — `reventless/aws/src/Platform_Stack.res`, the
   "Deprecated spellings" block (~line 389): `cognitoUserPoolId`,
   `cognitoUserPoolClientId`, `cognitoUserPoolArn` (has no readers at all),
   `cognitoRegion`, `cognitoUserPoolManaged`.
2. **The readers' fallback** — `reventless/aws/src/Platform.res` (~409–445): the
   `StackReference` reads fall back to `cognitoUserPoolId` / `cognitoRegion`,
   at both the direct and the ESM `default.<key>` level.
3. **Old `config.json` keys** — `Util_ShellConfig.identityFields`
   (`reventless/aws/src/util/Util_ShellConfig.res`) writes `cognitoUserPoolId`
   and `cognitoClientId` beside the new keys; update `Util_ShellConfigTest`.
4. **The deprecated input key** — `_deprecatedPoolIdKey` in `Platform_Stack.res`
   (~79–88), still read as a fallback for `identityProviderId`.
5. **The workflow secret fallback** — `COGNITO_USER_POOL_ID` in
   `.github/workflows/deploy-reventless-aws.yml` (the `workflow_call` input and
   the two `secrets.IDENTITY_PROVIDER_ID || secrets.COGNITO_USER_POOL_ID`
   lines) and in `deploy-online-shop-hybrid.yml` / `deploy-online-shop-aggregates.yml`.
6. Docs that still mention the old keys: `packages/doc/docs-infrastructure/ui-fragments-deployment.md`
   and `appsync-events-live-updates.md`.

## Why it waits, and in which order

- Items 3 and 1/2 need the shell that prefers the new keys to be the **pinned**
  one in every `platform-aws` (`config.json` is read at runtime; a bundle that
  only knows `cognitoClientId` gets `None` and login silently stops working).
  Checkable by reading `platform-aws/package.json`, not by hoping about caches.
- Items 4 and 5 are the dangerous ones: an absent provider id is **auto mode**,
  which creates a fresh user pool and orphans every existing account on a deploy
  that reports success. Remove them only after `IDENTITY_PROVIDER_ID` is
  confirmed set wherever these workflows run.

## Also never recorded

The parent's two-stacks-one-pool verification: two platform stacks on one
provider id, a role switch through either stack's resolver honoured by the next
token whichever trigger holds the slot, and a switch in one **not** narrowing the
caller's session in the other (`(sub, clientId)` keying, checked from decoded
tokens). Single-stack narrowing is live on alpha since 2026-09-09. Worth doing
the first time a second stack shares the pool, before the old names go.

## Done when

`grep -rn "cognitoUserPool\|cognitoRegion\|cognitoClientId\|COGNITO_USER_POOL_ID"`
over `reventless/aws/src` and `.github/workflows` returns only the type name
`cognitoUserPool` and comments, with a `feat(aws)!:` commit carrying a release
note.
