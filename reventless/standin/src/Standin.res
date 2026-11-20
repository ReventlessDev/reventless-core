// Stand-ins for the things and services at an app's edge. A stand-in sends what
// the real thing sends through the door the real thing will use, and is told
// things the way the real thing will be told them.

module Doors = Standin_Doors
module Kind = Standin_Kind
module Runtime = Standin_Runtime

type send = Standin_Kind.send = {slice: string, body: JSON.t}
type step<'state> = Standin_Kind.step<'state> = {state: 'state, sends: array<send>}
type answer = Standin_Kind.answer = Accepted | Refused(string) | NotReachable(string)

module Thing = {
  let make = Standin_Kind.thing
}

module Service = {
  let make = Standin_Kind.service
}
