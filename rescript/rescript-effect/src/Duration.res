// ReScript bindings for Effect Duration
// All functions imported from the "effect" package via the Duration namespace.

type t

@module("effect") @scope("Duration")
external millis: int => t = "millis"

@module("effect") @scope("Duration")
external seconds: int => t = "seconds"

@module("effect") @scope("Duration")
external minutes: int => t = "minutes"

@module("effect") @scope("Duration")
external hours: int => t = "hours"

@module("effect") @scope("Duration")
external days: int => t = "days"
