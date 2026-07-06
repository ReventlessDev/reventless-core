// AWS-side selection for the QueryDb (read model) storage backend — the QueryDb
// analogue of `EventLogBackend` / `DcbBackend` (B3.1,
// docs/plans/aws-postgres-querydb-adapter.md).
//
// When `Platform.MakeWithConfig` is given a `~pgConnection`, it records the
// resolved selection here BEFORE any admin/plugin `construct` runs. Read by:
//   - `QueryDbStorage.Selectable(Stream)` — route app read-model storage to
//     Postgres (no DynamoDB table) and bind the Postgres operation set;
//   - `QueryDbResolvers.Selectable` — suppress AppSync resolvers for
//     Postgres-backed read models (GraphQL reads land with B3.2's Lambda data
//     source; until then those fields are unresolved);
//   - the ReadModel/StateViewSlice runtime builders — inject `pgConnection` into
//     Postgres-backed handlers' HANDLER_CONFIG entries and put the projection
//     Lambdas in-VPC with secret access.
//
// ADMIN EXEMPTION: platform/admin read models (Plugins, UIFragmentRegistry, …)
// stay on DynamoDB even when Postgres is selected. Deploy-time consumers (the
// AppSync schema-clobber guard's Plugin-RM scan, `PLUGIN_RM_TABLE_NAME` gates,
// retire hooks) query these tables during `pulumi up` — from outside the VPC —
// and the whole platform lifecycle depends on them. The platform registers the
// exempt names before Admin.construct.

type selection = {
  connectionConfig: Pulumi.Output.t<PgConnection.connectionConfig>,
  /** DB-access security group every projection Lambda attaches (PgConnection.securityGroupId). */
  securityGroupId: Pulumi.Output.t<string>,
  /** Private subnets for the in-VPC projection Lambdas (PgConnection.subnetIds). */
  subnetIds: array<Pulumi.Input.t<string>>,
}

let selectionRef: ref<option<selection>> = ref(None)

/** Record the QueryDb Postgres selection. Called once by the platform before construct. */
let set = (sel: selection) => selectionRef := Some(sel)

/** The active QueryDb Postgres selection, if the platform was given a `PgConnection`. */
let get = (): option<selection> => selectionRef.contents

// Read-model names that stay on DynamoDB regardless of the selection.
let exemptNames: array<string> = []

/** Exempt an (admin) read model from the Postgres selection. Called by the
    platform for every admin read model before Admin.construct. */
let exempt = (name: string) => exemptNames->Array.push(name)->ignore

/** Whether this read model's QueryDb is Postgres-backed on this platform. */
let isPostgresFor = (name: string): bool =>
  selectionRef.contents->Option.isSome && !(exemptNames->Array.includes(name))

/** Whether ANY read model on this platform is Postgres-backed (used to decide
    whether the projection Lambdas need VPC/secret access). */
let isPostgres = (): bool => selectionRef.contents->Option.isSome

// B3.3: Postgres read models routed through `QueryDbStorage.SelectableStream`
// (i.e. subscription-enabled). Lives here — a leaf both the storage selector and
// the projection-Lambda runtime builders already import — so the runtime builder
// can consult it without pulling in QueryDbStorage (which would close a build
// cycle via QueryDbStorage_Postgres → PgQueryResolver_Builder). Membership means
// "publish live updates from the projection Lambda after save/delete".
let postgresStreamRegistry: Set.t<string> = Set.make()
