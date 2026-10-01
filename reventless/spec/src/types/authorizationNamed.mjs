// `Authorization.named`: a plugin's rule, whose roles are its own `Roles.t`
// cases, as the framework's rule over role names. A payload-less case is its
// name at run time, so the rule is returned as it is once every role has been
// checked to be one; anything else would be compared with group names and
// never match, so it is refused here instead.
export function named(rule) {
  if (rule !== null && typeof rule === "object" && rule.TAG === "AllowRoles") {
    for (const role of rule._0) {
      if (typeof role !== "string") {
        throw new Error(
          `Authorization: a role must be a case of a plugin's Roles.t without a payload, got ${JSON.stringify(role)}`,
        );
      }
    }
  }
  return rule;
}
