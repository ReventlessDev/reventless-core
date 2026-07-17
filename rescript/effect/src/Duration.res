/**
ReScript bindings for `Duration` — time interval values used with `Effect.sleep`,
`Effect.timeout`, and `Schedule` combinators.

**Example**
```rescript
Effect.sleep(Duration.seconds(5))
->Effect.zipRight(Effect.succeed("done"))
```
*/
type t

/** Duration of `n` milliseconds. */
@module("effect/Duration")
external millis: int => t = "millis"

/** Duration of `n` seconds. */
@module("effect/Duration")
external seconds: int => t = "seconds"

/** Duration of `n` minutes. */
@module("effect/Duration")
external minutes: int => t = "minutes"

/** Duration of `n` hours. */
@module("effect/Duration")
external hours: int => t = "hours"

/** Duration of `n` days. */
@module("effect/Duration")
external days: int => t = "days"
