// NotificationSourceClaims StateChangeSlice.
//
// Which streams of occurrences a second producer has taken over. One row per
// source, keyed by the source itself — `"<log>:<eventType>"`, opaque to everyone
// but the producers that agree on it.
//
// **Its own slice, and that is forced rather than preferred.** The claims could
// have lived on `NotificationPreferences`, which is the component that reads
// them. But a slice's DCB partition is derived from the `*Id` fields its own
// events declare, so a slice producing both `recipientId` and `sourceId` facts
// has two candidate partitions and resolves to neither. Split, each side
// produces one key: preferences are per recipient, claims are per source. The
// reading side then sees `sourceId` as a key it consumes but does not produce,
// which is exactly the shape the framework infers a cross-partition read from —
// see `NotificationPreferences.RequestNotification`.
//
// Nothing in this shop claims anything, so the set is permanently empty and every
// request is decided by the compiled table. That is the point: the handover costs
// nothing until somebody uses it.

@@reventless.spec

@schema
type consumedEvent =
  | NotificationSourceClaimed({sourceId: string, by: string})
  | NotificationSourceReleased({sourceId: string})

@schema
type command =
  // Relayed, never a client door — a caller who could claim a source would be
  // silencing everybody else's notifications from it.
  | @noApi ClaimNotificationSource({sourceId: string, by: string})
  | @noApi ReleaseNotificationSource({sourceId: string})

@schema
type error =
  // Both commands are idempotent — re-claiming what you already hold and
  // releasing what nobody holds both publish nothing — so there is no refusal to
  // make. Declared because the shape requires one, and named for what it would
  // mean if it were ever reachable.
  | ClaimRefused

@schema
type event =
  | NotificationSourceClaimed({sourceId: string, by: string})
  | NotificationSourceReleased({sourceId: string})

let traits = [TraitNotification.Notification.declaration]
