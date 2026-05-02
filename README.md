# marquetools/.github

Org-wide GitHub config for [marquetools](https://github.com/marquetools): reusable workflows, composite actions, and community-health defaults (issue/PR templates, dependabot, security policy).

## Reusable workflows

All reusable workflows live in [`.github/workflows/`](./.github/workflows/) and are called via:

```yaml
uses: marquetools/.github/.github/workflows/<name>.yml@<ref>
```

| Workflow | Purpose | Triggers in caller |
|---|---|---|
| [`claude-code-review.yml`](./.github/workflows/claude-code-review.yml) | Run Claude Code Action against PRs | `pull_request` |
| [`gemini-dispatch.yml`](./.github/workflows/gemini-dispatch.yml) | Entry point that routes `@gemini-cli` requests to review/triage/invoke/plan-execute | `pull_request`, `issues`, `issue_comment`, `pull_request_review`, `pull_request_review_comment` |
| [`gemini-review.yml`](./.github/workflows/gemini-review.yml) | Gemini PR review (called by dispatch) | `workflow_call` only |
| [`gemini-triage.yml`](./.github/workflows/gemini-triage.yml) | Gemini single-issue triage (called by dispatch) | `workflow_call` only |
| [`gemini-scheduled-triage.yml`](./.github/workflows/gemini-scheduled-triage.yml) | Hourly batch triage of unlabeled issues | `schedule`, `workflow_dispatch` |
| [`gemini-invoke.yml`](./.github/workflows/gemini-invoke.yml) | Free-form Gemini invocation (called by dispatch) | `workflow_call` only |
| [`gemini-plan-execute.yml`](./.github/workflows/gemini-plan-execute.yml) | Gemini plan execution (called by dispatch) | `workflow_call` only |

### Caller stubs

Drop these into `.github/workflows/` in each consumer repo. The workflow itself defines the trigger; the `uses:` line pulls in the org-shared logic.

#### Claude code review

```yaml
# .github/workflows/claude-code-review.yml
name: Claude Code Review
on:
  pull_request:
    types: [opened, synchronize, ready_for_review, reopened]
    paths:
      - "src/**"
      - "Cargo.toml"
jobs:
  review:
    uses: marquetools/.github/.github/workflows/claude-code-review.yml@main
    secrets: inherit
    permissions:
      contents: read
      pull-requests: read
      issues: read
      id-token: write
    with:
      # Optional overrides; defaults are sensible.
      mise_install_args: pnpm
      plugin_marketplaces: |
        https://github.com/anthropics/claude-code.git
        https://github.com/knitli/toolshed.git
      plugins: |
        code-review@claude-code-plugins
        strip-ansi@toolshed
```

Inputs: `plugin_marketplaces`, `plugins`, `prompt`, `allowed_bots`, `assignee_trigger`, `mise_install_args`, `mise_env`, `use_commit_signing`, `fetch_depth`. See the workflow file for defaults.

#### Gemini assistant (dispatch)

```yaml
# .github/workflows/gemini-dispatch.yml
name: Gemini Dispatch
on:
  pull_request_review_comment: { types: [created] }
  pull_request_review:         { types: [submitted] }
  pull_request:                { types: [opened] }
  issues:                      { types: [opened, reopened] }
  issue_comment:               { types: [created] }
jobs:
  dispatch:
    uses: marquetools/.github/.github/workflows/gemini-dispatch.yml@main
    secrets: inherit
    permissions:
      contents: read
      issues: write
      pull-requests: write
      id-token: write
```

Dispatch nests the review/triage/invoke/plan-execute reusable workflows internally — consumer repos do not need separate caller stubs for those.

#### Gemini scheduled triage

```yaml
# .github/workflows/gemini-scheduled-triage.yml
name: Gemini Scheduled Triage
on:
  schedule:
    - cron: '0 * * * *'
  workflow_dispatch:
jobs:
  triage:
    uses: marquetools/.github/.github/workflows/gemini-scheduled-triage.yml@main
    secrets: inherit
    permissions:
      contents: read
      issues: write
      pull-requests: read
      id-token: write
```

### Required vars and secrets

The Gemini workflows read these from the consumer repo's environment (forwarded via `secrets: inherit`):

- **Secrets**: `GEMINI_API_KEY` (or `GOOGLE_API_KEY`), `APP_PRIVATE_KEY` (optional, if using a GitHub App), `CLAUDE_CODE_OAUTH_TOKEN` (claude-code-review only)
- **Vars**: `APP_ID`, `GEMINI_MODEL`, `GEMINI_CLI_VERSION`, `GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_LOCATION`, `SERVICE_ACCOUNT_EMAIL`, `GCP_WIF_PROVIDER`, `GOOGLE_GENAI_USE_GCA`, `GOOGLE_GENAI_USE_VERTEXAI`, `UPLOAD_ARTIFACTS`, `GEMINI_DEBUG`, `GEMINI_CLI_TRUST_WORKSPACE`

Unset vars/secrets fall back to safe defaults; the workflows skip GitHub App token minting when `APP_ID` is empty.

## Composite actions

Live in [`actions/`](./actions/) and are referenced as `marquetools/.github/actions/<name>@<ref>`.

| Action | Purpose |
|---|---|
| [`actions/setup-mise`](./actions/setup-mise/action.yml) | Thin wrapper over `jdx/mise-action` with marquetools defaults. Installs mise and provisions tools from the consumer repo's `mise.toml`. |
| [`actions/strip-ansi`](./actions/strip-ansi/action.yml) | Wrapper over `marquetools/strip-ansi-action` for scanning files and PR/issue comments for ANSI/Unicode threats. |

### Using `setup-mise`

```yaml
- uses: marquetools/.github/actions/setup-mise@main
  with:
    github-token: ${{ secrets.GITHUB_TOKEN }}
    install-args: pnpm           # optional: install only one tool
    mise-env: dev                # optional: activate [env.dev] section
    cache-key-prefix: ci         # optional: scope the cache
```

All inputs are optional. With nothing set it does the equivalent of:

```yaml
- uses: actions/checkout@<sha>
- uses: jdx/mise-action@<sha>
  with:
    install: true
    experimental: true
    cache: true
    reshim: true
```

See [`actions/setup-mise/action.yml`](./actions/setup-mise/action.yml) for the full input list and outputs (`mise-path`, `mise-version`, `mise-env`).

## Pinning

Examples above use `@main` for readability. For production, pin to a tag or commit SHA — both for the reusable workflow ref *and* for the org actions referenced inside it. The reusable workflows currently reference `marquetools/.github/actions/setup-mise@main` internally; pin those too if you cut a release.
