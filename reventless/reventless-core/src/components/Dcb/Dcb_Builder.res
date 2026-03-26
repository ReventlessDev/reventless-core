type dcbResult = {
  dcbEventLogOutputs: option<DcbEventLog.outputs>,
  stateChangeSlicesOutputs: dict<StateChangeSlice.outputs>,
  stateViewSlicesOutputs: dict<StateViewSlice.outputs>,
  automationSlicesOutputs: dict<AutomationSlice.outputs>,
  outboundTranslationSlicesOutputs: dict<OutboundTranslationSlice.outputs>,
  inboundTranslationSlicesOutputs: dict<InboundTranslationSlice.outputs>,
  dcbRuntimeSetup: option<unit => unit>,
  mutationEntries: array<ReventlessInfra.Api.mutationSchemaEntry>,
  queryEntries: array<ReventlessInfra.Api.querySchemaEntry>,
  eventLogEntries: array<ReventlessInfra.Api.eventLogSchemaEntry>,
}

let emptyResult: dcbResult = {
  dcbEventLogOutputs: None,
  stateChangeSlicesOutputs: Dict.make(),
  stateViewSlicesOutputs: Dict.make(),
  automationSlicesOutputs: Dict.make(),
  outboundTranslationSlicesOutputs: Dict.make(),
  inboundTranslationSlicesOutputs: Dict.make(),
  dcbRuntimeSetup: None,
  mutationEntries: [],
  queryEntries: [],
  eventLogEntries: [],
}

module Make = (
  DcbEventLogStorage: DcbEventLog_Adapter.Storage,
  DcbEventTopicPublisher: EventTopic_Adapter.Publisher,
  DcbCommandTopicChannel: CommandTopic_Adapter.Channel,
  RuntimeBuilder: PluginRuntime_Builder.T,
) => {
  let construct = (
    ~name: string,
    ~childName: string,
    ~dcbSpec: option<module(Plugin.DcbSpec)>,
    ~opts: Pulumi.ComponentResource.options,
  ): dcbResult => {
    switch dcbSpec {
    | Some(module(DcbSpec)) => {
        // Run validation: check produced vs consumed event compatibility
        let produced =
          DcbSpec.stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            (Sc.Spec.name, Sc.Spec.producedEventSchema->S.castToUnknown)
          )
        let consumed =
          DcbSpec.stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            (Sc.Spec.name, Sc.Spec.consumedEventSchema->S.castToUnknown)
          )
          ->Array.concat(
            DcbSpec.stateViewSlices->Array.map((module(V: StateViewSlice.T)) =>
              (V.Spec.name, V.Spec.consumedEventSchema->S.castToUnknown)
            ),
          )
          ->Array.concat(
            DcbSpec.automationSlices->Array.map((module(A: AutomationSlice.T)) =>
              (A.Spec.name, A.Spec.consumedEventSchema->S.castToUnknown)
            ),
          )
          ->Array.concat(
            DcbSpec.outboundTranslationSlices->Array.map((module(O: OutboundTranslationSlice.T)) =>
              (O.Spec.name, O.Spec.consumedEventSchema->S.castToUnknown)
            ),
          )

        switch Reventless.DcbValidation.validateProducedAndConsumed(~produced, ~consumed) {
        | Error(errors) =>
          errors->Array.forEach(err =>
            Console.error(`DCB validation error (${err.sliceName}): ${err.message}`)
          )
        | Ok() => ()
        }

        // Extract tagged fields from all produced event schemas for DynamoDB GSI creation
        let indexes =
          produced
          ->Array.flatMap(((_, schema)) => Reventless.DcbTag.extractTaggedFields(schema))
          ->(arr => {
            let seen = Set.make()
            arr->Array.filter(f => {
              if seen->Set.has(f) {
                false
              } else {
                seen->Set.add(f)
                true
              }
            })
          })
          ->Array.map(tagKey => `tag_${tagKey}`)

        module DcbEventLog = DcbEventLog_Builder.Make(
          DcbEventLogStorage,
          DcbEventTopicPublisher,
        )
        let dcbEventLog = DcbEventLog.make(~name, ~indexes, ~opts)

        // Notify platform hook that DCB EventLog was created (AWS extracts table name)
        Plugin_Helpers.onDcbEventLogCreated.contents->Option.forEach(hook =>
          hook(dcbEventLog->Obj.magic)
        )

        // Create shared CommandTopic for all StateChangeSlices
        module DcbCommandTopicSpec = {
          module Id = Reventless.Id.String
          @schema
          type command = JSON.t
        }
        module DcbCommandTopic = CommandTopic_Builder.Make(
          DcbCommandTopicSpec,
          DcbCommandTopicChannel,
        )
        let dcbCommandTopic = DcbCommandTopic.make(~name=`${childName}-dcb-command-topic`, ~opts)

        // Notify platform hook that DCB CommandTopic was created (AWS extracts SQS queue URL)
        Plugin_Helpers.onDcbCommandTopicCreated.contents->Option.forEach(hook =>
          hook(dcbCommandTopic->Obj.magic)
        )

        let publishJsons =
          dcbCommandTopic
          ->Component.operations
          ->Pulumi.Output.apply(ops => ops.publishJsons)

        let stateChangeSlicesOutputs =
          DcbSpec.stateChangeSlices
          ->Array.map((module(StateChangeSlice: StateChangeSlice.T)) => {
            let ch = StateChangeSlice.make(~dcbEventLog, ~publishJsons, ~opts)
            (StateChangeSlice.Spec.name, ch->Component.outputs)
          })
          ->Dict.fromArray

        // Phase 1: Register DCB mutation SDL + resolver stubs via platform hook
        switch Plugin_Helpers.mutationResolverHook.contents {
        | Some(registerResolver) =>
          DcbSpec.stateChangeSlices->Array.forEach((
            module(S: StateChangeSlice.T),
          ) => {
            registerResolver(
              ~kind=Dcb,
              ~fields=[Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)],
              ~commandSchema=S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema,
            )
          })
        | None => ()
        }

        // Phase 2: Bind generateCommand to resolver stubs when publishJsons resolves
        switch Plugin_Helpers.mutationBindHook.contents {
        | Some(bindHandler) =>
          let _ =
            dcbCommandTopic
            ->Component.operations
            ->Pulumi.Output.apply(ops => {
              DcbSpec.stateChangeSlices->Array.forEach((
                module(S: StateChangeSlice.T),
              ) => {
                let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)
                let generateCommand = CommandGenerator_Callback.makeGenerateCommand(
                  ~publishJsons=ops.publishJsons,
                  ~serviceName=S.Spec.name,
                  ~commandSchema=S.Spec.commandSchema->Obj.magic,
                  ~stripIdFromParams=false,
                )
                bindHandler(~field=fieldName, ~generateCommand)
              })
            })
        | None => ()
        }

        // Populate query field names registry for all slice types BEFORE creating them
        DcbSpec.stateViewSlices->Array.forEach((
          module(V: StateViewSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=V.Spec.name)
          Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.set(V.Spec.name, qn)
        })

        DcbSpec.automationSlices->Array.forEach((
          module(A: AutomationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=A.queryDbName)
          Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.set(A.queryDbName, qn)
        })

        DcbSpec.outboundTranslationSlices->Array.forEach((
          module(O: OutboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=O.queryDbName)
          Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.set(O.queryDbName, qn)
        })

        DcbSpec.inboundTranslationSlices->Array.forEach((
          module(I: InboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=I.queryDbName)
          Plugin_Helpers.queryFieldNamesRegistry.contents->Dict.set(I.queryDbName, qn)
        })

        // Create StateViewSlices
        let stateViewSlicesOutputs =
          DcbSpec.stateViewSlices
          ->Array.map((module(StateViewSlice: StateViewSlice.T)) => {
            let sv = StateViewSlice.make(~dcbEventLog, ~opts)
            (StateViewSlice.Spec.name, sv->Component.outputs)
          })
          ->Dict.fromArray

        // Create AutomationSlices
        let automationSlicesOutputs =
          DcbSpec.automationSlices
          ->Array.map((module(AutoSlice: AutomationSlice.T)) => {
            let as_ = AutoSlice.make(~dcbEventLog, ~publishJsons, ~opts)
            (AutoSlice.Spec.name, as_->Component.outputs)
          })
          ->Dict.fromArray

        // Create OutboundTranslationSlices
        let outboundTranslationSlicesOutputs =
          DcbSpec.outboundTranslationSlices
          ->Array.map((module(OTS: OutboundTranslationSlice.T)) => {
            let ots = OTS.make(~dcbEventLog, ~publishJsons, ~opts)
            (OTS.Spec.name, ots->Component.outputs)
          })
          ->Dict.fromArray

        // Create InboundTranslationSlices
        let inboundTranslationSliceData =
          DcbSpec.inboundTranslationSlices->Array.map((
            module(ITS: InboundTranslationSlice.T),
          ) => {
            let its = ITS.make(~publishJsons, ~opts)
            let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=ITS.Spec.name)

            switch Plugin_Helpers.inboundMutationResolverHook.contents {
            | Some(registerResolver) =>
              registerResolver(
                ~fieldName,
                ~externalInputSchema=ITS.Spec.externalInputSchema->S.castToUnknown,
              )
            | None => ()
            }

            switch Plugin_Helpers.inboundMutationBindReceiveHook.contents {
            | Some(bindReceive) =>
              let _ =
                its
                ->Component.operations
                ->Pulumi.Output.apply(ops => bindReceive(~fieldName, ~receive=ops.receive))
            | None => ()
            }

            (ITS.Spec.name, fieldName, its, ITS.Spec.externalInputSchema->S.castToUnknown)
          })

        let inboundTranslationSlicesOutputs =
          inboundTranslationSliceData
          ->Array.map(((specName, _, its, _)) => (specName, its->Component.outputs))
          ->Dict.fromArray

        // Collect InboundTranslationSlice receive functions for composite handler routing
        let inboundReceiversOutput =
          inboundTranslationSliceData
          ->Array.map(((_, fieldName, its, _)) =>
            its
            ->Component.operations
            ->Pulumi.Output.apply(ops => (fieldName, ops.receive))
          )
          ->Pulumi.Output.all
          ->Pulumi.Output.apply(pairs => pairs->Dict.fromArray)

        // Composite handler: SQS commands (StateChangeSlice) + direct invocations (InboundTranslation)
        // + AppSync direct invocations (CommandGenerator.payload format)
        let dcbHandlerBase = DcbCommandTopic.makeFilteringHandler(dcbCommandTopic)

        // Shared generateCommand for AppSync direct invocations — all StateChangeSlices
        // share the same DCB CommandTopic's publishJsons, so a single function suffices.
        // commandSchema validation is skipped (permissive JSON.t schema) because AppSync
        // already validates input against the SDL.
        let dcbGenerateCommandOutput =
          dcbCommandTopic
          ->Component.operations
          ->Pulumi.Output.apply(ops =>
            CommandGenerator_Callback.makeGenerateCommand(
              ~publishJsons=ops.publishJsons,
              ~serviceName=name,
              ~commandSchema=S.json->S.castToUnknown,
              ~stripIdFromParams=false,
            )
          )

        let dcbHandler =
          (dcbHandlerBase, inboundReceiversOutput, dcbGenerateCommandOutput)
          ->Pulumi.Output.all3
          ->Pulumi.Output.apply(((baseHandler, receivers, generateCommand)) => {
            let composite = (event, ctx) => {
              let raw: dict<JSON.t> = event->Obj.magic
              switch raw->Dict.get("__inboundTranslation") {
              | Some(_) =>
                let fieldName =
                  raw
                  ->Dict.get("fieldName")
                  ->Option.flatMap(JSON.Decode.string)
                  ->Option.getOr("")
                let args = raw->Dict.get("arguments")->Option.getOr(JSON.Encode.null)
                switch receivers->Dict.get(fieldName) {
                | Some(receiveFn) =>
                  Effect.promise(async () => {
                    let result = await receiveFn(args)
                    let response = switch result {
                    | Ok(id) => id
                    | Error(msg) => msg
                    }
                    response->Obj.magic
                  })
                | None => baseHandler(event, ctx)
                }
              | None =>
                // Check for CommandGenerator.payload format (AppSync direct invocation)
                switch (raw->Dict.get("command"), raw->Dict.get("arguments")) {
                | (Some(JSON.String(_)), Some(_)) =>
                  let payload: CommandGenerator.payload = event->Obj.magic
                  (generateCommand(payload)->Effect.map(msgId => msgId->Obj.magic))->Obj.magic
                | _ => baseHandler(event, ctx)
                }
              }
            }
            composite->Obj.magic
          })

        // Resources the Lambda needs access to
        let dcbResources = Array.concat(
          stateChangeSlicesOutputs->Dict.valuesToArray->Array.flatMap(outputs => outputs.resources),
          inboundTranslationSlicesOutputs
          ->Dict.valuesToArray
          ->Array.flatMap(outputs => outputs.resources),
        )

        let inboundFieldNames =
          inboundTranslationSliceData->Array.map(((_, fieldName, _, _)) => fieldName)
        let inboundSchemas = inboundTranslationSliceData->Array.map(((_, _, _, schema)) => schema)

        // Collect DCB mutation field names + TAGs for AppSync resolver creation
        let dcbMutationData =
          DcbSpec.stateChangeSlices->Array.map((
            module(S: StateChangeSlice.T),
          ) => {
            let fieldName = Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)
            let constructorNames =
              Reventless.DcbTag.extractEventTypes(S.Spec.commandSchema->Obj.magic)
            let tag = constructorNames->Array.get(0)->Option.getOr(S.Spec.name)
            (fieldName, tag)
          })
        let dcbFieldNames = dcbMutationData->Array.map(((f, _)) => f)
        let dcbTags = dcbMutationData->Array.map(((_, t)) => t)

        let dcbConnectFn = (~runtime) => {
          DcbCommandTopic.connect(~runtime, ~resources=dcbResources, dcbCommandTopic)

          if inboundFieldNames->Array.length > 0 {
            switch Plugin_Helpers.inboundAppSyncResolverHook.contents {
            | Some(hook) =>
              hook({
                runtime: runtime->Obj.magic,
                fieldNames: inboundFieldNames,
                externalInputSchemas: inboundSchemas,
                opts,
              })
            | None => ()
            }
          }

          if dcbFieldNames->Array.length > 0 {
            switch Plugin_Helpers.dcbAppSyncResolverHook.contents {
            | Some(hook) =>
              hook({
                runtime: runtime->Obj.magic,
                fieldNames: dcbFieldNames,
                tags: dcbTags,
                opts,
              })
            | None => ()
            }
          }
        }

        // Notify platform hook that all DCB slices are created (AWS calls finish on bundled builders).
        // Pass dcbEventLog so the platform can wait for its operations to resolve before calling finish().
        Plugin_Helpers.onDcbSlicesCreated.contents->Option.forEach(hook =>
          hook(dcbEventLog->Obj.magic)
        )

        let dcbRuntimeSetup = () =>
          dcbCommandTopic->RuntimeBuilder.forDcbCommandTopic(
            ~handler=dcbHandler,
            ~connect=dcbConnectFn,
          )

        // DCB-specific API schema entries
        let mutationEntriesFromSlices =
          DcbSpec.stateChangeSlices->Array.map((
            module(S: StateChangeSlice.T),
          ) => {
            ReventlessInfra.Api.fieldNames: [Api_Naming.sliceMutationField(~plugin=name, ~slice=S.Spec.name)],
            commandSchema: S.Spec.commandSchema->Reventless.DcbTag.toUnknownSchema,
          })

        let mutationEntriesFromInboundSlices =
          DcbSpec.inboundTranslationSlices->Array.map((
            module(ITS: InboundTranslationSlice.T),
          ) => {
            ReventlessInfra.Api.fieldNames: [Api_Naming.sliceMutationField(~plugin=name, ~slice=ITS.Spec.name)],
            commandSchema: ITS.Spec.externalInputSchema->S.castToUnknown,
          })

        let stateViewEntries = DcbSpec.stateViewSlices->Array.map((
          module(V: StateViewSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForStateView(~plugin=name, ~viewName=V.Spec.name)
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: V.Spec.stateSchema->Reventless.DcbTag.toUnknownSchema,
            authorization: None,
            includeIdParam: false,
          }
        })

        let automationEntries = DcbSpec.automationSlices->Array.map((
          module(A: AutomationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=A.queryDbName)
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: AutomationSlice_Callback.todoRowSchema->S.castToUnknown,
            authorization: None,
          }
        })

        let outboundEntries = DcbSpec.outboundTranslationSlices->Array.map((
          module(O: OutboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=O.queryDbName)
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: OutboundTranslationSlice_Callback.todoRowSchema->S.castToUnknown,
            authorization: None,
          }
        })

        let inboundEntries = DcbSpec.inboundTranslationSlices->Array.map((
          module(I: InboundTranslationSlice.T),
        ) => {
          let qn = Api_Naming.queryFieldNamesForSliceQueryDb(~plugin=name, ~queryDbName=I.queryDbName)
          {
            ReventlessInfra.Api.singleFieldName: qn.singleFieldName,
            listFieldName: qn.listFieldName,
            returnTypeName: qn.returnTypeName,
            stateSchema: InboundTranslationSlice_Callback.auditRowSchema->S.castToUnknown,
            authorization: None,
          }
        })

        // Collect all event schemas from produced events for eventLogEntries
        let allProducedSchemas =
          DcbSpec.stateChangeSlices->Array.map((module(Sc: StateChangeSlice.T)) =>
            Sc.Spec.producedEventSchema->S.castToUnknown
          )

        {
          dcbEventLogOutputs: Some(dcbEventLog->Component.outputs),
          stateChangeSlicesOutputs,
          stateViewSlicesOutputs,
          automationSlicesOutputs,
          outboundTranslationSlicesOutputs,
          inboundTranslationSlicesOutputs,
          dcbRuntimeSetup: Some(dcbRuntimeSetup),
          mutationEntries: Array.concat(mutationEntriesFromSlices, mutationEntriesFromInboundSlices),
          queryEntries: stateViewEntries
            ->Array.concat(automationEntries)
            ->Array.concat(outboundEntries)
            ->Array.concat(inboundEntries),
          eventLogEntries: if allProducedSchemas->Array.length > 0 {
            // Use the first produced event schema as representative for the event log
            [
              {
                ReventlessInfra.Api.busKey: name ++ "DcbEventLog",
                displayName: name,
                eventSchema: allProducedSchemas->Array.getUnsafe(0),
              },
            ]
          } else {
            []
          },
        }
      }
    | None => emptyResult
    }
  }
}
