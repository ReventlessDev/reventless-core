// A Yoga plugin that reports each GraphQL operation once it is done: its kind, its name, the
// root fields it asked for, who asked, how long it took and the errors it answered with. A
// subscription is reported when it starts. Introspection, and a request carrying the
// `x-reventless-watch` header (a tool watching the platform), are not reported.

const watchHeader = "x-reventless-watch";

const operationOf = (document, operationName) => {
  const ops = (document?.definitions ?? []).filter((d) => d.kind === "OperationDefinition");
  return operationName ? ops.find((o) => o.name?.value === operationName) : ops[0];
};

const describe = (args, ms, errors) => {
  const op = operationOf(args.document, args.operationName);
  const fields = (op?.selectionSet?.selections ?? [])
    .filter((s) => s.kind === "Field")
    .map((s) => s.name.value);
  const report = {
    kind: op?.operation ?? "query",
    fields,
    ms,
    errors,
  };
  const name = args.operationName ?? op?.name?.value;
  if (name) report.operationName = name;
  const user = args.contextValue?.identity?.username;
  if (user) report.user = user;
  return report;
};

const skipped = (args) => {
  const op = operationOf(args.document, args.operationName);
  const fields = (op?.selectionSet?.selections ?? []).filter((s) => s.kind === "Field");
  const introspection = fields.length > 0 && fields.every((s) => s.name.value.startsWith("__"));
  const headers = args.contextValue?.request?.headers;
  const watching = typeof headers?.get === "function" && headers.get(watchHeader) != null;
  return introspection || watching;
};

const errorsOf = (result) =>
  result && Array.isArray(result.errors) ? result.errors.map((e) => String(e?.message ?? e)) : [];

export function requestLog(report) {
  return {
    onExecute({ args }) {
      if (skipped(args)) return undefined;
      const started = performance.now();
      return {
        onExecuteDone({ result }) {
          // An incremental result (defer, stream) has no single answer to report errors from.
          const errors = result && typeof result[Symbol.asyncIterator] === "function" ? [] : errorsOf(result);
          report(describe(args, Math.round(performance.now() - started), errors));
        },
      };
    },
    onSubscribe({ args }) {
      if (!skipped(args)) report(describe(args, 0, []));
    },
  };
}
