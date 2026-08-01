// Import products from supplier JSON files uploaded to S3.
// Each row is forwarded as `externalInput` to the ImportProduct
// InboundTranslationSlice, which validates and translates to an AddProduct
// command. Style purity: the Task drives a DCB slice, not an aggregate.

@@reventless.task

let importCallback = (~eventName, ~key) => {
  if eventName->String.includes("ObjectCreated") {
    Console.log("[ImportProducts] Processing file: " ++ key)

    let meta: Message.meta = {
      service: "ImportProducts",
      time: Date.now()->Float.toString,
      ip: "",
      user: "system",
      msgId: key,
      correlationId: key,
    }

    // Stub demo payload — in a real implementation the bucket key would be
    // fetched and parsed. We push a hard-coded supplier line through the
    // InboundTranslationSlice so the wire-up is exercised end-to-end.
    let demoInput: ImportProduct.externalInput = {
      sku: key,
      title: "Imported Product",
      desc: "Imported from " ++ key,
      unitPrice: 999,
      currency: "USD",
    }

    [
      Task.PublishCommands(
        ImportProduct.name,
        [
          {
            id: key,
            meta,
            commandJson: demoInput->Message.encode(ImportProduct.externalInputSchema),
          },
        ],
      ),
    ]->Promise.resolve
  } else {
    []->Promise.resolve
  }
}

let setup = (_queryEngine, _queryBucketName, _opts) => {
  Task.buckets: [
    {
      bucketMode: Task.Read,
      callback: importCallback,
    },
  ],
}
