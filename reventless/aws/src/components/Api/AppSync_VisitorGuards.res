// What a deployment on a public address must have before a role may be signed up
// for: the door and its guards are deployed together, never one at a time. A
// starting state of closed does not relax this, because a demo opens the role on
// that same public address.
//
// Pure, so the refusal is tested without a deploy.

type guard =
  /** Addresses are kept as fingerprints, and the limit counts sources under one. */
  | FingerprintKey
  /** A check that a person, not a script, is signing up. */
  | PersonCheck
  /** A mail sender that keeps bounces off its list and stops at a daily cap. */
  | BoundedSender
  /** An alarm on what mail, accounts and requests cost. */
  | BillAlarm

/** What this deployment has. A guard the framework does not provide yet is said
    as missing, so a role stays closed to the public until it does. */
type has = {
  fingerprintKey: bool,
  personCheck: bool,
  boundedSender: bool,
  billAlarm: bool,
}

let describe = (guard: guard): string =>
  switch guard {
  | FingerprintKey => "a fingerprint key: set the secret platform:fingerprintKey on the platform stack (32 characters or more, and never changed afterwards)"
  | PersonCheck => "a check that a person is signing up, which the framework does not provide yet"
  | BoundedSender => "a mail sender that keeps bounced addresses off its list: a messaging sender on the platform, which then makes its configuration set; deploy the platform stack again first"
  | BillAlarm => "an alarm on the bill: set platform:operatorAddress on the platform stack, the address its alarms and budget write to"
  }

let missing = (has: has): array<guard> =>
  [
    (has.fingerprintKey, FingerprintKey),
    (has.personCheck, PersonCheck),
    (has.boundedSender, BoundedSender),
    (has.billAlarm, BillAlarm),
  ]->Array.filterMap(((present, guard)) => present ? None : Some(guard))

/** The roles a plugin's structure declares self-service. */
let selfServiceRoles = (structure: Reventless.Plugin.pluginStructure): array<string> =>
  switch structure.admission->Option.map(Reventless.Admission.fromDefs) {
  | Some(Ok(table)) => table->Reventless.Admission.selfService->Array.map(r => (r :> string))
  | Some(Error(_)) | None => []
  }

/** Why the plugin is not deployed, if it declares a self-service role on a
    deployment that lacks a guard: every missing one is named. */
let refusal = (~plugin: string, ~roles: array<string>, has: has): option<string> =>
  switch (roles, missing(has)) {
  | ([], _) | (_, []) => None
  | (roles, guards) =>
    Some(
      `${plugin}: ${roles->Array.join(
          ", ",
        )} can be signed up for by visitors, and this deployment lacks what a public address needs for that:\n` ++
      guards
      ->Array.map(g => `  - ${describe(g)}`)
      ->Array.join(
        "\n",
      ) ++ `\nThe door for visitors and its guards are deployed together. Until then, declare the role Provisioned or Invitation, or host this plugin on the local platform.`,
    )
  }
