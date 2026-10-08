/** Bindings for [`node:timers`](https://nodejs.org/api/timers.html): Node's own
    timers, whose handle is an object that can be told not to keep the process
    alive. rescript-web's timers are the portable ones; reach for these only
    where that object is wanted. */
type timeout

/** Delays are milliseconds. */
@module("node:timers")
external setTimeout: (unit => unit, int) => timeout = "setTimeout"

@module("node:timers")
external clearTimeout: timeout => unit = "clearTimeout"

/** Runs every `int` milliseconds until cleared. Its handle is a `timeout` too,
    so `unref` applies. */
@module("node:timers")
external setInterval: (unit => unit, int) => timeout = "setInterval"

@module("node:timers")
external clearInterval: timeout => unit = "clearInterval"

/** Lets the process exit while the timer is still pending: a backstop that
    must not be the reason a process stays up. */
@send external unref: timeout => unit = "unref"
