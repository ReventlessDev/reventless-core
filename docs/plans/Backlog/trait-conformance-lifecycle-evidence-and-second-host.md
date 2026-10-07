# Plan: trait conformance suites count as lifecycle evidence, and a trait proves itself on a second host

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/trait-address-geocoding.md](../done/trait-address-geocoding.md) when it closed. Both items are optional: nothing is wrong today, the lifecycle model simply has less evidence than it could, and the host contract is validated on one host only.<br/>
**Relates to:** [../trait-file-attachment.md](../trait-file-attachment.md) (its attachment trait already has two hosts, `ProductImages` and `CategoryImages`), [../conformance-test-kit.md](../conformance-test-kit.md)

---

## 1. Conformance suites emit no `.gwt.json` sidecar

**In plain words.** `pnpm run check:lifecycle` builds `src/LifecycleModel.res` from what the plugin's
GWT scenarios show about each command (which states it is allowed from, which it moves to). The PPX
writes that evidence as a `.gwt.json` sidecar beside every file annotated `@@reventless.gwt`. A
trait's conformance suite is registered from a functor instead
(`AddressGeocoding_Conformance.Make(Binding).register()`, likewise `Attachments_Conformance` and
`Notification_Conformance`), so its scenarios leave no sidecar.

**Effect today.** In `examples/online-shop-hybrid/schema/lifecycle-model.json`, `SetLocation` is
backed by one scenario from a kept host GWT and `MarkAddressUnresolvable` does not appear at all —
the conformance suite asserts both, but the model cannot see it. Nothing is contradicted (both are
`@noApi` and declare no `@transition`), so this costs evidence, not correctness.

**Done when** the scenarios a conformance suite runs reach the lifecycle harvest — either the runner
writes a sidecar itself, or the host's `*Conformance_GWT.res` wrapper gets one from the PPX — and the
golden lists the trait's commands with their scenario counts.

## 2. Prove the geocoding contract on a second host

**In plain words.** `AddressGeocoding.Binding` was written from one host, the hybrid `Customer`
aggregate. The scaffold (`AddressGeocoding_Scaffold`) and the binding are validated by transcription
from that host only, so whether the contract really is host-independent is untested (the plan's
risk R1).

**Done when** a second aggregate with an address — in an example, not in a framework package —
grafts the trait from its scaffold and passes the unchanged conformance suite, and
`scripts/check-trait-pack.mjs` lists that pair too. Pull this when a second host is wanted for its
own sake; building one only to test the contract is the generalisation the plan warned against.
