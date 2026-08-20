// Facade for the seeding harness.
//
// A seed run is: build a list of mutations from typed domain commands, send
// them through the public GraphQL API in phases, then verify what the views
// actually contain. Nothing here knows about a specific domain — the mapping
// from a plugin's command types to `mutation` values is the caller's adapter.

module Random = Seed_Random
module Client = Seed_Client
module Runner = Seed_Runner
module Upload = Seed_Upload
module Prompt = Seed_Prompt
module Users = Seed_Users
module Connect = Seed_Connect

exception Failed = Seed_Types.Failed

// A live target a data set seeds against: an authenticated client, whether uploads
// are skipped this run, and a label. Uploads mint through the domain API's
// `Upload_Presign` mutation on the client (route B), so no upload endpoint is carried.
type connection = Seed_Connect.connection = {
  client: Seed_Client.t,
  uploadsSkipped: bool,
  label: string,
}

// A named, seedable data set. `seed` owns everything domain-specific.
type dataSet = Seed_Runner.dataSet = {
  name: string,
  label: string,
  seed: connection => promise<unit>,
  probeViews?: array<string>,
}

type rec value = Seed_Types.value =
  | String(string)
  | Id(string)
  | Int(int)
  | Float(float)
  | Bool(bool)
  | Enum(string)
  | List(array<value>)
  | Object(array<(string, value)>)

type mutation = Seed_Types.mutation = {field: string, args: array<(string, value)>}

let mutation = Seed_Types.mutation
let ids = Seed_Types.ids
let strings = Seed_Types.strings
let describe = Seed_Types.describe
