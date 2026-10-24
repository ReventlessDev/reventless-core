/**
A value held for a few minutes, outside the event log, and handed over once.

For the step between a door and the component that acts on what the door
received, when the value must reach a provider and must never reach the log: a
password typed on a set-a-password form, held until the proof that came with it
has been checked by a `decide` that the door itself cannot run. The door puts it
under a key both sides can name, and the slice that reacts to the accepted proof
takes it.

**Taken once, and gone after its time.** A second `take` answers `None`, so a
value cannot be read twice; a value nobody takes expires, so a refused proof
leaves nothing behind for long. Neither is a promise of secrecy at rest — that is
the backend's — but both bound how long and how often a secret is exposed.
*/
type failure = Unavailable(string)

type t = {
  /** Hold `value` under `key` for at most `ttl` seconds. Putting under a key that
      already holds a value replaces it: the newer request is the one in flight. */
  put: (~key: string, ~value: string, ~ttl: Duration.t) => promise<result<unit, failure>>,
  /** The value under `key`, removed as it is read; `None` when nothing is held or
      it has expired. */
  take: (~key: string) => promise<result<option<string>, failure>>,
}

/** A stash that holds nothing, refusing both operations — what a platform that
    provisions none answers, so a slice declaring the need is told rather than
    handed a store that silently forgets. */
let unavailable = (~reason: string): t => {
  put: async (~key as _, ~value as _, ~ttl as _) => Error(Unavailable(reason)),
  take: async (~key as _) => Error(Unavailable(reason)),
}

let failureReason = (Unavailable(reason): failure): string => reason
