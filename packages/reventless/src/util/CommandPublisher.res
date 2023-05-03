module type Spec = {
  @decco
  let name: string
  @decco
  type command
}

module type Config = {
  let user: string
  let publishCommands: Task.publishCommands
}

let batchSize = 10

module Make = (Spec: Spec, Config: Config) => {
  let batch = ref([])
  let promises = []

  let send = () => {
    let batchCount = promises->Belt.Array.size
    Js.log(`sending batch ${batchCount->Belt.Int.toString}:`)
    let commandJsons = batch.contents->Belt.Array.mapWithIndex((idx, (id, command)) => {
      let commandJson = command->Spec.command_encode
      Js.log(`  ${idx->Belt.Int.toString}: ${id}: ${commandJson->Js.Json.stringify}`)
      {
        ReventlessSpec.Message.id,
        meta: Reventless.Message.generateMeta(~service=Spec.name, ~user=Config.user, ()),
        commandJson,
        delay: None,
      }
    })
    let p = Config.publishCommands(. Spec.name, commandJsons)
    let _ = promises->Js.Array2.push(p)
    batch := []
  }

  let publish = (id: string, command: Spec.command) => {
    batch := batch.contents->Belt.Array.concat([(id, command)])
    if batch.contents->Belt.Array.size >= batchSize {
      send()
    }
  }

  let flush = async () => {
    send()
    let _results = await promises->Js.Array2.removeFromInPlace(~pos=0)->Util.Promise.allSettled
  }
}
