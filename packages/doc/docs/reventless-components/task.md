---
title: Task
date: 2021-11-22
draft: true
---

The Task's business logic is defined in it's setup function. Contrary to the Command/Event paradigm used across the other components, the Task is free to be implemented in any way. Often Tasks are used to interact with third party systems (e.g. API calls, upload/download).

In the setup function, resources may be instanciated using [Pulumi](../inner-workings/pulumi.md). Additionally a Side Effect Handler can react to events. 

### Task Setup


```rescript title="ExampleTask.res"
let taskName = "ExampleTask"

let setup = (.
  queryEngine: ReventlessSpec.QueryEngine.t,
  scheduler: ReventlessSpec.Scheduler.t,
  publishCommands: Reventless.Task.publishCommands,
  queryBucketName,
  allEventTopics,
  opts,
) => {
// implementation
}
```

The setup function is run during deploy time. An example why that might be useful is useful to create external resources. Code that needs to be executed at runtime needs to be passed via a callback. To illustrate this, consider the following example:

```rescript title="CustomerTask.res"
let taskName = "ProfilePictureTask"

let idFromKey = key => key->Js.String2.split(".")->Belt.Array.getExn(0)

let publishCommand = (publishCommands, id, command) => {
  publishCommands(.
    Customer.name,
    [
      {
        Reventless.Message.id,
        meta: Reventless.Message.generateMeta(~service=Customer.name, ~user=taskName, ()),
        commandJson: command->Customer.command_encode,
        delay: None,
      },
    ],
  )
}

let setup = (.
  _queryEngine: ReventlessSpec.QueryEngine.t,
  _scheduler: ReventlessSpec.Scheduler.t,
  publishCommands: Reventless.Task.publishCommands,
  _queryBucketName,
  _allEventTopics,
  opts,
) => {
  let bucket = {
    open PulumiAws.S3.Bucket
    make(
      ~name=taskName ++ "Bucket",
      ~args=Args.make(
        ~corsRules=[
          CorsRule.make(
            ~allowedHeaders=["*"],
            ~allowedMethods=["HEAD", "GET"],
            ~allowedOrigins=["*"],
            ~exposeHeaders=[
              "x-amz-server-side-encryption",
              ">x-amz-request-id",
              "x-amz-id-2",
              "ETag",
            ],
            ~maxAgeSeconds=3000,
          ),
        ]->Pulumi.Input.make,
        (),
      ),
      ~opts,
      (),
    )
  }

  let callback = async (event, _) => {
    // retrieve relevant data from lambda event (AWS Infra Event - NOT event defined by codebase)
    let record = event["_Records"][0]
    let eventName = record["eventName"]
    let key = Js.Global.decodeURIComponent(record["s3"]["_object"]["key"]) // s3 object key
    // calculate id - by convention the image file has to be named like this: <customerId>.<fileExtension>
    Js.log2(`${taskName} triggered:`, key)

    // for possible event names, see: https://docs.aws.amazon.com/AmazonS3/latest/userguide/notification-how-to-event-types-and-destinations.html#supported-notification-event-types
    let isDeletion = eventName->Js.String2.indexOf("ObjectRemoved") > 0
    let isCreation = eventName->Js.String2.indexOf("ObjectCreated") > 0

    if isCreation {
      let id = idFromKey(key)
      publishCommand(publishCommands, id, Customer.ChangeProfilePicture(Some(key)))->ignore
    } else if isDeletion {
      let id = idFromKey(key)
      publishCommand(publishCommands, id, Customer.ChangeProfilePicture(None))->ignore
    }
    // TODO: error handling of promises etc.
  }

  let handler = {
    open PulumiAws.Lambda.CallbackFunction
    make(
      ~name=taskName,
      ~args=Args.make(
        ~callback,
        ~memorySize=4096->Pulumi.Input.make,
        ~timeout=600->Pulumi.Input.make,
        (),
      ),
      (),
    )
  }

  bucket->PulumiAws.S3.Bucket.onObjectCreated(~name=taskName, ~handler, ~opts, ())->ignore

  {
    "bucket": Some(bucket),
    "name": taskName,
    "sideEffectHandler": None,
  }
}

let make: Reventless.Task.maker = Reventless.Task.make(~name=taskName, ~setup)

```

First, we define a name for the function. For now, ignore the idFromKey and publishCommand functions. 
Then as usual, the setup function is defined. Note that unused parameter variables can be underscored to get rid of compiler warnings. 

In this setup function, an AWS S3 Bucket gets created using pulumi. By defining a callback and a handler, we can start a lambda and execute code when a file is placed into the bucket. 

Note the publishCommand function in the callback which will send a command to an aggregate for the given id. This is how reventless can observe events coming from external systems. 

Using a Task to generate and use Cloud resources is not the only way how a Task can be used. Other common use cases could be: 
- Scheduling
- HTTP Calls
- DNS Routing
- etc.

## Side Effect Handler

In the ProfilePictureTask example we have seen how external Systems can act as Command or Event Sources in Reventless. But what about the other way around? For this, we can make use of a Side Effect Handler. It registers on an Event Topic and in response to an Event, executes code.

## Creating a Task

let make: Reventless.Task.maker = Reventless.Task.make(~name=taskName, ~setup)




