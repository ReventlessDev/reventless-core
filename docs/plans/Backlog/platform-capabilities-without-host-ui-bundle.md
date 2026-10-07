# Plan: geocoding and messaging are provisioned without a host-UI bundle

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/customer-address-backend-geocoding.md](../done/customer-address-backend-geocoding.md) when it closed (its *Open* list: "the geocoder is provisioned only inside `switch hostUiBundle`"). Waits for a decision on where capability handles are declared, and for a headless deployment that needs them; every deployed platform today passes `~hostUiBundle`.<br/>
**Relates to:** [../baked-manifest-without-host-ui-bundle.md](../baked-manifest-without-host-ui-bundle.md) (open — the same binding, for the baked manifest), [../done/declared-object-stores-without-host-ui-bundle.md](../done/declared-object-stores-without-host-ui-bundle.md) (the precedent that settled it for object stores)

---

## In plain words

A **capability** is something the platform provides and plugin code calls through an injected port
— `geocode` (address → point) and `messaging` (send a notification). A **headless** platform is one
deployed without the host-UI shell (`~hostUiBundle` omitted), for example because the UI is deployed
from its own stack. Geocoding and messaging are not UI features, yet a headless platform cannot
provision either.

## What is left

In `reventless/aws/src/Platform.res`, both capability handles are fields of `hostUiBundleConfig`:

- `geocoderPlaceIndex?` — the place index from `Capability_Geocoding_AwsLocation.make`. Its
  `Query.geocode` resolver, the `geocoderPlaceIndex` stack export (read by `deployPlugin` for the
  slice path's `PLACE_INDEX_NAME`), and the "plugin declares `Geocoding` but no index is provisioned"
  deploy gate all sit inside `switch hostUiBundle { | Some(cfg) => … }`.
- `messagingSender?` — the SES sender from `Capability_Messaging_Ses.make`; its stack exports
  (`messagingEmailSender`, `messagingEmailProvider`) sit in the same branch.

So on a headless platform the exports are absent, the plugin side reads `""`, and the gate's own
error message tells the deployer to pass the index "in `~hostUiBundle`".

## The shape of the fix

The object-store plan already decided the principle: provisioning and its exports belong to the
platform stack unconditionally; only what the *shell* consumes stays in the shell branch.

1. Move `geocoderPlaceIndex` and `messagingSender` out of `hostUiBundleConfig` to a platform-level
   argument (beside `~capabilities`), and their exports and the deploy gate outside the
   `hostUiBundle` switch.
2. Keep the `Query.geocode` resolver tied to split-API mode as it is now — it lives on the domain
   API, not on the shell.
3. Decide this together with the baked-manifest plan, so `hostUiBundleConfig` is reshaped once
   rather than in two breaking changes.

**Done when** a platform deployed without `~hostUiBundle` but with both handles exports
`geocoderPlaceIndex` and the messaging sender, and a plugin's geocoding slice resolves an address on
it. A `pulumi preview` of a platform that *does* pass a bundle shows no resource change.
