// In-memory task bucket.
// No S3 buckets created; makeHandler calls the callback with extracted event fields.

open ReventlessCore

type runtimeParts = LocalRuntimeEnvironment.parts
type callbackEvent = JSON.t
type context = unit
type bucketParts = unit

let connect: Task_Adapter.connect<bucketParts, runtimeParts> = (
  ~name as _,
  ~bucket as _,
  ~bucketMode as _,
  ~commandTopics as _,
  ~runtime as _,
  ~opts as _,
) => ()

let makeHandler = (callback: Task.bucketCallback): Runtime.eventHandler<
  callbackEvent,
  context,
  array<Task.taskAction>,
> => {
  async (json, _ctx) => {
    let eventName = switch json {
    | JSON.Object(d) =>
      d
      ->Dict.get("eventName")
      ->Option.flatMap(j =>
        switch j {
        | JSON.String(s) => Some(s)
        | _ => None
        }
      )
      ->Option.getOr("ObjectCreated")
    | _ => "ObjectCreated"
    }
    let key = switch json {
    | JSON.Object(d) =>
      d
      ->Dict.get("key")
      ->Option.flatMap(j =>
        switch j {
        | JSON.String(s) => Some(s)
        | _ => None
        }
      )
      ->Option.getOr("")
    | _ => ""
    }
    await callback(~eventName, ~key)
  }
}

let make: Task_Adapter.bucketMaker<bucketParts> = (~name, ~opts as _) => {
  // When SQLite is the active backend, eagerly provision the task_object
  // table so put/get helpers can be used outside the bucketMaker contract.
  switch BackendState.getDb() {
  | Some(db) => TaskBucket_Sqlite.ensureSchema(db)
  | None => ()
  }
  // Return a single dummy resource so Task_Builder can access Array.getUnsafe(0).id.
  {
    resources: [
      ReventlessInfra.Adapter.make(
        ~name=name->Pulumi.Output.make,
        ~id=name->Pulumi.Output.make,
        ~urn=("urn:" ++ name)->Pulumi.Output.make,
        ~service="memory:InMemory"->Pulumi.Output.make,
      ),
    ],
    parts: (),
  }
}
