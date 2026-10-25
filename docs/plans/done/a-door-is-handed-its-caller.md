# Plan: a door is handed its caller

**Date:** 2026-10-25<br/>
**Status:** ✅ **Done 2026-10-25.** Steps [C1](#c1-the-seam) to [C3](#c3-the-translations) built; the [open question](#open-questions) decided yes. What landed is under each step<br/>
**Repos:** `reventless-core` only. `reventless/spec` (`InboundTranslationSlice`), `reventless/core`
(`InboundTranslationSlice_Callback`), `reventless/gwt` (`InboundTranslation_GWT`), and the eleven
translations under `examples/` and `reventless/` that take `~capabilities` today.<br/>
**Found by:** the registration plan's per-role admission
([Admission per role](../self-registration-is-a-chapter-not-a-trait.md#admission-per-role--planned-2026-10-24)):
a door that invites has to know who is inviting before any command exists.<br/>
**After:** [an inbound translation is gated the same way at every door](an-inbound-translation-is-gated-and-encoded-like-a-command.md),
which carried the caller as far as the callback ([its *Carrying the caller*](an-inbound-translation-is-gated-and-encoded-like-a-command.md#carrying-the-caller))
and stopped there.

## In plain words

When somebody calls a door, the platform already knows who they are: the callback that runs the
door is handed the caller and checks every command the door produces against the caller's rule.
The door's own code, the `translate` function, is not told. That is fine for a door that only
maps input to commands, which is what every door did until now. It is not fine for a door that
must look at the caller before it decides what to send: an invitation names a role, and only a
caller holding one of the roles the declaration lists may send it; a webhook acts as a role, and a
translation that wants to record which one has nothing to read. This plan hands `translate` the
caller the callback already holds, and nothing else changes.

## What is there

`InboundTranslationSlice_Callback.receive` takes `~caller: option<Reventless.Identity.t>`: the
identity the transport built, `None` where the platform acts for itself. After `translate` returns,
each command's rule is checked against that caller, and one refused refuses the whole input. The
check is right and stays. What is missing is the caller on the way *in*, so a door can refuse
before it does anything with its capabilities, and can put the caller's id into a command as data.

The GWT harness runs the slice's own `translate` against capability fakes, so it needs the same
argument to drive a door that reads it.

## Design

- **`translate` gains `~caller`**, with the type `receive` already has:
  `(externalInput, ~capabilities, ~caller: option<Reventless.Identity.t>) => promise<result<…>>`.
  `None` keeps its meaning, the platform acting for itself, so a door that wants a person refuses
  `None` and a door that wants nothing ignores it. No new identity value is introduced: an
  anonymous caller is already `Identity.anonymous`, built by the resolver.
- **The callback passes what it was handed**, unchanged, before the per-command check it already
  runs. A door that refuses on the caller answers like any other translation error, recorded in
  the audit row; a door that lets a command through still has that command checked against the
  caller's rule, so handing the caller in widens nothing.
- **The harness takes `~caller=?`** on `whenInput` and `whenReceived`, defaulting to `None`, so
  existing scenarios keep their meaning and a door scenario names its caller.
- **Every translation that only maps input** takes `~caller as _`, as it takes `~capabilities as _`.

A door that acts on the caller before any command exists is the shape the registration plan's
admission table asks for: the check is the door's, the grant is the ledger's, and the ledger never
has to trust a role name a door put in a command without being able to check who put it there.

## Steps

Numbered C1 to C3. **C** stands for *caller*.

### C1: the seam

The signature in `reventless/spec`, the callback passing the caller, and the structure's reading of
the door unchanged. A translation that reads the caller must still compile against the module type.

**Exit:** `rescript build` green across the repository once [C3](#c3-the-translations) is done; the
callback's test shows a translation refusing on `None` and on an identity lacking a role, each
recorded as a translation error with no command published.

**Built.** `Translation.translate` takes `~caller: option<Identity.t>` beside `~capabilities`, and
`InboundTranslationSlice_Callback.receive` passes on what it was handed, before the per-command
check it already ran. `InboundTranslationSliceCallbackTest` drives a door that admits only `Admin`:
with no caller and with a `Shopper` it is refused with the door's own message, no error code, and
nothing published; an administrator is let through.

### C2: the harness

`whenInput` and `whenReceived` take `~caller=?`; `Capabilities_Fake` is untouched. A scenario can
say *when the caller is `admin`* and read the outcome.

**Exit:** a GWT on a door that reads the caller, written with the harness.

**Built.** `whenInput(input, ~caller=identity)` and `whenReceived(json, ~caller=…)`, the caller left
out meaning the platform acting for itself. `InboundFromSliceGwtTest` drives a door that confirms a
payment marked paid by hand only for a `Finance` caller, through both verbs.

### C3: the translations

The eleven existing translations take `~caller as _`. The two registration doors keep ignoring it:
sign-up and completion are anonymous, and the caller tells them nothing they may act on.

**Exit:** every example builds and its suite is green; no behavior changed.

**Built.** Four translations live in sources now, not eleven — the two catalog imports and the two
registration doors — and the rest were test doors; each takes `~caller as _`. The one direct call of
a translation outside the platform, the hybrid seed's dry run of the catalog import, passes
`~caller=None`.

## Decisions

- The caller is handed to `translate` as the callback holds it, an option, rather than as a new
  type. The platform acting for itself stays `None`.
- The per-command check after `translate` stays. The caller in is for refusing early and for
  recording who acted; it replaces no gate.
- A webhook's translation receives the role the endpoint acts as, through the same argument: the
  identity the webhook route builds carries that role's group, so nothing is special-cased.

## Open questions

1. **Should a door's audit row name the caller?** It names the input and the outcome today.
   *Recommendation:* yes, the caller's `userId` beside the input, redacted as the input is; a door
   that refuses on the caller should leave a row that says who was refused.
   **Decided yes, and built:** the row gains an optional `caller`, the `userId`, written on success
   and on refusal and absent where the platform acted for itself. It is optional, so rows written
   before it still decode, and it reaches each door's audit view in the GraphQL schema.

## Acceptance

- A translation can refuse an input on the caller alone, before touching a capability, and the
  refusal is recorded like any other translation error.
- No translation that ignores the caller changed behavior; the full suite is green.
- The GWT harness drives a door with a named caller.
