// The domain API's introspection, built from the committed SDL golden, so a test
// can read what a running platform would answer without one.
import { readFileSync } from "node:fs";
import { buildSchema, introspectionFromSchema } from "graphql";

export const read = () =>
  introspectionFromSchema(
    buildSchema(readFileSync(new URL("../../schema/domain-api.graphql", import.meta.url), "utf8")),
  );
