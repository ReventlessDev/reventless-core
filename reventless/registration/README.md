# @reventlessdev/reventless-registration

Self-registration as a library of slices. A person with no account proves control of
an address and ends up with one, in the groups of the roles the app admits them to.
Verify, then create: nothing makes an account until the proof settles, and "this
address is taken" is a DCB claim tag on the address, decided identically on every
platform.

A plugin is per app, so this package is not a plugin. An app's plugin lists it in
`src/plugin.json` and supplies its admission table:

```json
{
  "name": "Registration",
  "slicesFrom": [{"package": "@reventlessdev/reventless-registration", "with": "Admission"}]
}
```

```rescript
// src/Admission.res, over the plugin's own Roles.t
let table = Reventless.Admission.declare([(Roles.Shopper, SelfService), (Admin, Provisioned)])
```

The plugin also lists this package in its `dependencies` and in its `rescript.json`
dependencies. The generator composes the slices as the plugin's own, under the
`Registration` chapter.

| Slice | Kind | What it does |
|---|---|---|
| `RegistrationPolicy` | StateChange, administrators only | Opens and closes a self-service role, optionally until a time |
| `Registrations` | StateChange, relayed commands only | The ledger, partitioned by address. Besides a sign-up's arms, it takes an invitation (`Invite`), a reissued code and a withdrawal, which no door here reaches |
| `RegistrationWindows` | StateViewStream, anonymous | Which self-service roles are open now |
| `SignUp` | Inbound, anonymous | Starts a registration for a role |
| `CompleteRegistration` | Inbound, anonymous | Takes the proof and the password; the password goes to the stash, never to the log |
| `SendRegistrationChallenge` | Outbound, `Messaging` | Sends the code, or tells a registered address someone tried |
| `CreateRegisteredPrincipal` | Outbound, `Stash` + `IdentityProvider` | Makes the account once the proof is accepted |

A closed role, a role no visitor may have, a taken address and a fresh one all answer
an anonymous caller alike; only what arrives at the address differs.

The package ships the doors a visitor uses and no invitation door. A plugin that
provides one lists it beside these slices, marks it `let admissionDoor =
Reventless.Admission.Invite`, checks the inviter's roles, and relays `Invite` to the
ledger. The ledger refuses any role the app's table does not declare by invitation.
An invitation's code holds a week; a sign-up's holds a day.

The scenarios that pin these slices run in the plugins that list them, against that
plugin's own table: in this repository, `examples/online-shop-hybrid/registration`.

The doors admit anonymous callers, which only the local platform does today, so a
plugin listing these slices is hosted by the local platform only.
