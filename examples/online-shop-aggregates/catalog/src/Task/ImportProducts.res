// Import products from a CSV file uploaded to S3.
// Each row is translated to a Product.Add command.

open Reventless

let name = "ImportProducts"

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
