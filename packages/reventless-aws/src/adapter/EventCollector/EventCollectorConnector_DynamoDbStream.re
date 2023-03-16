open PulumiAws;

let make: Reventless.EventCollector.Adapter.connectorMaker =
  (
    ~name,
    ~eventTopics,
    ~handleEvents,
    ~memorySize,
    ~timeout,
    ~policy1=?,
    ~policy2=?,
    ~opts,
  ) => {
    Reventless.Logger.logOutput(
      ~loc=__LOC__,
      "policy1",
      policy1->Belt.Option.getWithDefault(Pulumi.Output.make("None")),
    );
    Reventless.Logger.logOutput(
      ~loc=__LOC__,
      "policy2",
      policy2->Belt.Option.getWithDefault(Pulumi.Output.make("None")),
    );
    let policies = PulumiAws.Lambda.Policy.customPolicies(policy1, policy2); // TODO calculate real policies
    Reventless.Logger.logOutput(
      ~loc=__LOC__,
      "policies",
      policies->Pulumi.Output.all,
    );

    let eventHandlerLambda =
      policies
      ->Pulumi.Output.all
      ->Pulumi.Output.apply(policies => {
          Reventless.Logger.log(
            ~loc=__LOC__,
            "eventHandlerLambda-policies",
            policies,
          );
          Lambda.CallbackFunction.make(
            ~name,
            ~args=
              Lambda.CallbackFunction.Args.make(
                ~callback=
                  EventCollectorConnector_DynamoDbStream_Runtime.handleStreamEvent(
                    handleEvents,
                  ),
                ~policies,
                ~memorySize=memorySize->Pulumi.Input.make,
                ~timeout=timeout->Pulumi.Input.make,
                (),
              ),
            ~opts,
            (),
          );
        });

    let _ =
      eventTopics
      ->Reventless.Util.Adapter.partitionSupportedResources([|
          Util_DynamoDbStream_Runtime.service,
          Util_SNS_FIFO.service,
        |])
      ->Pulumi.Output.apply(((dynamoDbStreamResources, errorResources)) => {
          let _eventSourceMappings: array(EventSourceMapping.t) =
            dynamoDbStreamResources->Belt.Array.map(((sourceName, sources)) =>
              Util_EventSourceMapping.subscribe(
                ~batchSize=25,
                ~lambda=eventHandlerLambda,
                ~targetName=name,
                ~sourceName,
                ~source=
                  sources[0]->Reventless.AdapterDeploytime.unwrappedToResource,
                ~opts,
                (),
              )
            );

          if (errorResources->Belt.Array.length > 0) {
            let eventTopicNames = errorResources->Js.Array2.joinWith(",");
            Js.Exn.raiseError(
              __MODULE__
              ++ {j| cannot connect to EventTopic(s) $eventTopicNames|j},
            );
          };
        });

    {
      Reventless.EventCollector.Adapter.resources: [||],
      enqueueEvent:
        (. delay, id, messageBody) =>
          // TODO: can we check this at deploy time ?
          Js.log4(
            __MODULE__ ++ " supports no enqueueEvent:",
            delay,
            id,
            messageBody,
          )
          ->Js.Promise.resolve,
    };
  };
