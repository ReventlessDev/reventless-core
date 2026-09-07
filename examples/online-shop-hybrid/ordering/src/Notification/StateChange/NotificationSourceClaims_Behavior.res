@@reventless.behavior

// The claim set is the trait's, folded through the same value the preferences
// slice folds. Only the claim half of it is ever populated here — a claim says
// nothing about who anybody is or what they want.
module Rules = TraitNotification.Notification_Rules

type state = Rules.t

let initialState = Rules.empty

let evolve = (state, event: consumedEvent) =>
  switch event {
  | NotificationSourceClaimed({sourceId, by}) =>
    state->Rules.evolve(Claimed({source: sourceId, by}))
  | NotificationSourceReleased({sourceId}) => state->Rules.evolve(Released({source: sourceId}))
  }

// No posture is consulted on either arm, so the table this passes is never read.
// Passing the trait's own decision function anyway keeps the idempotence rule in
// one place rather than restating it here.
let posture = (_category: string, _channel: Rules.channel) => false

let named = (fact: Rules.fact) =>
  switch fact {
  | Claimed({source, by}) => Some(NotificationSourceClaimed({sourceId: source, by}))
  | Released({source}) => Some(NotificationSourceReleased({sourceId: source}))
  // The other facts belong to the preferences slice; this one produces none of
  // them, and the two commands below cannot reach them.
  | _ => None
  }

let through = (state, op) =>
  switch state->Rules.decide(op, ~posture) {
  | Ok(facts) => Ok(facts->Array.filterMap(named))
  | Error(#RecipientUnknown) => Error(ClaimRefused)
  }

let decide = (state, command) =>
  switch command {
  | ClaimNotificationSource({sourceId, by}) => through(state, Claim({source: sourceId, by}))
  | ReleaseNotificationSource({sourceId}) => through(state, Release({source: sourceId}))
  }
