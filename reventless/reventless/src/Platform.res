// Platform module type — abstract factory interface for platform-agnostic component assembly.
//
// Re-exports ReventlessSpec.Platform so app code can use either:
//   - ReventlessSpec.Platform.T (preferred — no dependency on reventless)
//   - Reventless.Platform.T (backward compat alias)
//
// Usage pattern:
//
//   // app/MyPlugin.res — imports reventless-spec, NOT reventless-aws
//   module Make = (Platform: ReventlessSpec.Platform.T) => {
//     module MyAggregate = Platform.Aggregate.Make(MySpec, MyBehavior, MyMappings)
//     module MyReadModel = Platform.ReadModel.Make(MyRmSpec, MyMappings)
//     // ...
//   }
//
//   // index.res — Composition Root; the only file that imports reventless-aws
//   module Platform = ReventlessAws.Platform.Make(Config)
//   module App = MyPlugin.Make(Platform)

include ReventlessSpec.Platform
