/**
Telling one thing at an app's edge something: *charge at 11 kW*, *unlock*.

An outbound translation names the kind of thing and the instance, and the
message with its body; which provider carries it (a device broker, a charging
backend, the stand-ins of a local platform) is the platform's business, never
the domain's.

**Three answers, all modeled.** The thing took it; it refused, with its reason;
or it could not be reached, as a real thing that is offline. A platform with no
provider answers the last, so a translation's work stays queued and visible
rather than being written off.
*/
type answer =
  | Accepted
  | Refused(string)
  | NotReachable(string)

type t = {
  tell: (~kind: string, ~instance: string, ~message: string, ~body: JSON.t) => promise<answer>,
}

/** A provider that reaches nothing: what a platform with no devices provider answers. */
let unreachable = (~reason: string): t => {
  tell: async (~kind as _, ~instance as _, ~message as _, ~body as _) => NotReachable(reason),
}

let describe = (answer: answer): string =>
  switch answer {
  | Accepted => "accepted"
  | Refused(why) => `refused: ${why}`
  | NotReachable(why) => `not reachable: ${why}`
  }
