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
@module("effect") @scope("Duration")
external millis: int => t = "millis"

/** Duration of `n` seconds. */
@module("effect") @scope("Duration")
external seconds: int => t = "seconds"

/** Duration of `n` minutes. */
@module("effect") @scope("Duration")
external minutes: int => t = "minutes"

/** Duration of `n` hours. */
@module("effect") @scope("Duration")
external hours: int => t = "hours"

/** Duration of `n` days. */
@module("effect") @scope("Duration")
external days: int => t = "days"
