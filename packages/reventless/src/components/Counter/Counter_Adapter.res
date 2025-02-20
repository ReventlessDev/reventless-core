type handler = {addToCounterTarget: Counter.addToCounterTarget}

type handlerMaker = (
  ~name: string,
  ~referencesName: string,
  ~referencesDb: QueryDb.outputs,
  ~countsName: string,
  ~countsDb: QueryDb.outputs,
  ~counterHandler: Counter_Callback.counterHandler,
  ~opts: Pulumi.CustomResourceOptions.t,
) => handler

module type Handler = {
  let make: handlerMaker
}
