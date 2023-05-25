# `aws-lambda-layer` (WIP)

This tool takes a module specification (e.g. `@reventless/reventless-aws@latest`) and bundles this module with all it's dependencies into a zip file. This zip file can be then used to create an aws lambda layer ([see aws docs](https://docs.aws.amazon.com/lambda/latest/dg/configuration-layers.html)).

**NOTE: This is currently work in progress and may not be finished or contain bugs!**

## Example Usage

The `example` directory holds an application, to create a lambda layer for the `reventless-aws` package and all it's dependencies.

If necessary, update the target version of `reventless-aws` in the `index.js` file and run the node application afterwards:

```
cd example
node index.js
```

The application will create/update a zip file called `reventless-layer.zip` inside the `example` directory. To create a (new) Lambda layer:

- go to the AWS console
- go to the AWS Lambda section, and select `Layer`
- create a new or update an existing layer by uploading the created zip file
