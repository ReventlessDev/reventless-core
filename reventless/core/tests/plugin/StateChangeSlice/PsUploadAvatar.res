// Test fixture spec where every semantic carrier is OPTIONAL.
//
// The marker of an optional field sits on the schema *inside* the
// undefined-union sury-ppx wraps it in, so a walk that reads only the outer
// schema finds nothing. That failure is silent in the worst way: the plugin
// compiles, deploys green, and provisions no object store — so `avatarUrl` is
// the only declarer of `avatars` here on purpose. If the unwrap regresses, the
// store requirement disappears entirely rather than merely losing a site.
//
// `referredBy` is the same trap for `@ref`: an optional reference that goes
// uncollected drops out of `commandDef.references`.

@@reventless.spec("UploadAvatar")

type state = bool
let initialState = false

@schema
type consumedEvent = OrderPlaced

let evolve = (_state, _event) => true

@schema
type command =
  | UploadAvatar({
      customerId: string,
      @storageRef("avatars") avatarUrl?: string,
      @ref("Customers") referredBy?: string,
    })

@schema
type error = CustomerNotFound

@schema
type event = AvatarUploaded({customerId: string, @storageRef("avatars") avatarUrl?: string})

let decide = (_state, _command): result<array<event>, error> => Ok([])
