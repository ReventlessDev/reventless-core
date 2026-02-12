const conventionalChangelogAngular = require('conventional-changelog-angular');

module.exports = conventionalChangelogAngular.then(config => {
  // Modify the main template to reduce blank lines
  config.writerOpts.mainTemplate = `{{> header}}

{{#each commitGroups}}
{{#if title}}
### {{title}}

{{/if}}
{{#each commits}}
{{> commit root=@root}}
{{/each}}
{{/each}}
{{> footer}}
`;

  return config;
});
