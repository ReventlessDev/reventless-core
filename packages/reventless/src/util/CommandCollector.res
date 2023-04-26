module type Spec = {
  @decco
  type command
}

let batchSize = 10

module Make = (Spec: Spec) => {
  let batch = ref([])

  let send = () => {
    Js.log("sending batch:")
    batch.contents->Belt.Array.forEachWithIndex((idx, (id, command)) =>
      Js.log(
        `  ${idx->Belt.Int.toString}: ${id}: ${command->Spec.command_encode->Js.Json.stringify}`,
      )
    )
    batch := []
    Js.Promise2.resolve()
  }

  let add = (id: string, command: Spec.command) => {
    batch := batch.contents->Belt.Array.concat([(id, command)])
    if batch.contents->Belt.Array.size >= batchSize {
      send()
    } else {
      Js.Promise2.resolve()
    }
  }

  let flush = send
}
