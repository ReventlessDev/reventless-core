const angular = require('conventional-changelog-angular');

module.exports = function(config) {
  return angular(config).then(preset => {
    // Modify the main template to reduce blank lines
    preset.writerOpts.mainTemplate = `{{> header}}

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

    return preset;
  });
};
