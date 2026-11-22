# Repository rules

- This plugin knows no other plugin. Outside `CHANGELOG.md` and `wiki/ARCHIVE/`, no file names
  another plugin or uses its identifiers, scripts or environment variables;
  `tests/manifest-lint.sh` enforces it.
- Callers run `plugins/cc-codex-triage/scripts/review-state.sh` by its install path. Its usage
  line, exit codes and approval marker line are a public contract, written down in the plugin
  README's "Contract for callers". Keep them stable; changing one is a breaking change.
