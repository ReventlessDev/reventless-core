# Plan: the Notification trait's remaining items each wait on a decision

**Date:** 2026-10-07<br/>
**Status:** Backlog — extracted from [../done/trait-notification.md](../done/trait-notification.md) when it closed. Nothing here is buildable as code until someone decides the question it names; the plan's delivered parts (rules as data, the renderer, provenance, `@sensitive`, the subject on the delivery row, the digest routing field) are all shipped.<br/>
**Relates to:** [../done/domain-trait-extraction-online-shop-hybrid.md](../done/domain-trait-extraction-online-shop-hybrid.md) (the umbrella that named notification's Part 2)

---

## In plain words

The trait (`traits/notification`, `@reventlessdev/trait-notification`) turns host events into
notifications through a **rule table** — which event earns which category and what the message says
— and delivers them per recipient's preferences. One host grafts it: the hybrid `ordering` plugin.

## What is left, and the question each one waits on

| Item | Where in the parent | The question |
|---|---|---|
| **P4 — an open category vocabulary.** `NotificationPreferences.category` is a closed `@schema` variant; P4 makes categories configured data, with the variant as the seeded set. | §14 | Who may write a category's `posture` (notify-unless-opted-out vs. only-if-opted-in), and how that write is audited. It must be a distinct authorization from ordinary preference writes. A decision, not code. |
| **The digest components.** The rule's `delivery: Immediate \| Digest({windowSeconds})` field is shipped; nothing gathers a digest (a `NotificationDigest` StateChangeSlice plus a window AutomationSlice, per §19). | §19, §19.1 | Whether a digest earns two new components in an example plugin to demonstrate a routing field the table already carries. |
| **The raw-consumption posture on `OutboundTranslationSlice`.** Its metadata half (`consumedSources`) is shipped; the posture — subscribe to a list of logs and hand `translate` raw JSON — is not. | §15.2 | Nothing needs it until a rule table is configured at runtime, so it follows P4. Keep the source-name fail-fast and add a schema-drift check when it is built. |
| **A deploy/boot recheck of `validate`.** `validate(~digestRouted)` refuses a digest rule nobody can gather, but runs only in the host's GWT. | §19.1 ⚠️ | Enough while the table is compiled; needed the moment P4 lets a table arrive at runtime. |
| **Releasing a claim.** `ClaimNotificationSource` / `ReleaseNotificationSource` are built, tested and inert; nothing releases a claim. | §13.4 | **Do not build** while routing lives on the rule table — nothing makes a claim. Reopen only if a producer in a *foreign* plugin needs a source, which first needs a door (an ExtensionPoint) that no trait ships (§13a). |

## Order, if any of it is pulled

P4's decision first; then the `validate` recheck and the raw posture, which only matter once tables
are configured at runtime. The digest is independent of all three. The claim release stays dormant
unless the door question is answered.
