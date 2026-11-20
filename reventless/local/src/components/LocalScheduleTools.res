// The local platform's schedules as tools of its domain MCP server: list them, and fire one now,
// at the current time, as the `/__inmemory/schedules` routes do. An assistant can then run the
// month's settlement without waiting for the month's end, and nothing is backdated.

let listName = "local_schedules"
let fireName = "local_fire_schedule_now"

let schedulesText = () =>
  LocalAutomationSchedules.list()
  ->Array.map(s =>
    `${s.slice} ${s.key}: ${s.next->Option.mapOr("fires no more", at =>
        "next " ++ Date.fromTime(at)->Date.toISOString
      )}`
  )
  ->Array.join("\n")

let register = () => {
  DomainMCP_Server.registerTool(
    ~name=listName,
    ~definition={
      name: listName,
      description: "The automations' schedules on this local platform, each with when it next fires.",
      inputSchema: JSON.parseOrThrow(`{"type": "object", "properties": {}}`),
    },
    ~handler=async (_, _) =>
      McpSdk_Helpers.toolResult(
        switch schedulesText() {
        | "" => "No schedule is set."
        | text => text
        },
      ),
  )
  DomainMCP_Server.registerTool(
    ~name=fireName,
    ~definition={
      name: fireName,
      description: "Fires one schedule now, at the current time, as if it were due. Its next firing stays where it was.",
      inputSchema: JSON.parseOrThrow(`{
        "type": "object",
        "properties": {
          "slice": {"type": "string", "description": "The automation, as the schedules list names it."},
          "key": {"type": "string", "description": "The schedule's key, as the schedules list names it."}
        },
        "required": ["slice", "key"]
      }`),
    },
    ~handler=async (args, _) => {
      let field = k =>
        args
        ->JSON.Decode.object
        ->Option.flatMap(d => d->Dict.get(k))
        ->Option.flatMap(JSON.Decode.string)
      switch (field("slice"), field("key")) {
      | (Some(slice), Some(key)) =>
        switch await LocalAutomationSchedules.fireNow(~slice, ~key) {
        | Ok(at) =>
          McpSdk_Helpers.toolResult(
            `Fired ${key} of ${slice} at ${Date.fromTime(at)->Date.toISOString}.`,
          )
        | Error(e) => McpSdk_Helpers.toolError(e)
        }
      | _ => McpSdk_Helpers.toolError("Give the slice and the key.")
      }
    },
  )
}
