# codex-quota-widget

This repository is a public MIT-licensed macOS Swift application. It provides a menu bar and floating dashboard for locally available Codex quota, reset timing, reset cards, and daily token aggregates.

## Public and privacy boundary

- Treat every tracked file, example, test fixture, issue reference, and generated release artifact as public.
- Never add secrets, tokens, credentials, real account data, session text, private databases, personal absolute paths, or employer/client-restricted material.
- Quota and usage collection must remain read-only. Keep CLI installation and login setup user-confirmed; do not add automatic account mutations, actions that consume reset cards, or transmission of local usage data.
- Keep build output, local databases, developer configuration, signing material, and other machine-local state ignored by Git.
- This is an isolated open-source repository. Workspace registration may locate it, but its code, configuration, data, and runtime must not depend on personal or professional sibling repositories.

## Source and verification

- `Sources/CodexQuotaWidget/` contains application code and local data adapters.
- `Tests/CodexQuotaWidgetTests/` contains isolated unit tests.
- `assets/` contains public application resources.
- `scripts/` contains local build and packaging helpers.
- Run `swift test` after source or model changes. For packaging changes, also run `scripts/package_app.sh` and inspect the generated app locally.

Keep changes focused and preserve the documented privacy contract. A request to modify files does not by itself authorize commit, push, release, publication, account mutation, or destructive cleanup.
