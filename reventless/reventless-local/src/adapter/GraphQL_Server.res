// Backwards-compatibility re-export of DomainGraphQL_Server.
// The domain singleton was extracted to DomainGraphQL_Server.res as part of
// the Phase 6 symmetric server refactor. This file re-exports everything so
// existing imports (tests, adapters referencing GraphQL_Server.*) continue to
// compile without changes. New code should import DomainGraphQL_Server directly.
include DomainGraphQL_Server
