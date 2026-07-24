// Facade for the seeding harness.
//
// A seed run is: build a list of mutations from typed domain commands, send
// them through the public GraphQL API in phases, then verify what the views
// actually contain. Nothing here knows about a specific domain — the mapping
// from a plugin's command types to `mutation` values is the caller's adapter.

module Random = Seed_Random
module Client = Seed_Client
module Runner = Seed_Runner

exception Failed = Seed_Types.Failed

type rec value = Seed_Types.value =
  | String(string)
  | Id(string)
  | Int(int)
  | Float(float)
  | Bool(bool)
  | Enum(string)
  | List(array<value>)

type mutation = Seed_Types.mutation = {field: string, args: array<(string, value)>}

let mutation = Seed_Types.mutation
let ids = Seed_Types.ids
let strings = Seed_Types.strings
let describe = Seed_Types.describe
