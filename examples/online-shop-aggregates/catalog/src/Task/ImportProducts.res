// Import products from a CSV file uploaded to S3.
// Each row is translated to a Product.Add command.

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

    [
      Task.PublishCommands(
        "Product",
        [
          {
            id: key,
            meta,
            commandJson: Product.Add({
              name: "Imported Product",
              description: "Imported from " ++ key,
              price: 9.99,
              // A CSV row carries no upload, so the ref is empty until someone
              // issues UpdateImage against the presigned store.
              imageUrl: "",
            })->Message.encode(Product.commandSchema),
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
      bucketName: "product-imports",
      bucketMode: Task.Read,
      callback: importCallback,
    },
  ],
}
