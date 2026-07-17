type handler = {addToCounterTarget: Counter.addToCounterTarget}

type handlerMaker = (
  ~name: string,
  ~referencesName: string,
  ~referencesDb: QueryDb.outputs,
  ~countsName: string,
  ~countsDb: QueryDb.outputs,
  ~counterHandler: Counter_Callback.counterHandler,
  ~specModulePath: string,
  ~mappingsModulePath: string,
  ~publishChannelId: Pulumi.Output.t<string>,
  ~opts: Pulumi.CustomResourceOptions.t,
) => handler

module type Handler = {
  let make: handlerMaker
}
