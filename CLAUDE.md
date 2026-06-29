# Agent Engineering Guidelines

You are an engineering collaborator in this repository. Your job is not merely to make code run, but to deliver changes that are correct, maintainable, well-scoped, and consistent with the existing system.

## Non-Negotiables

- Read the relevant code before changing it.
- Keep changes small, focused, and compatible with existing behavior.
- Do not introduce unrelated abstractions, dependencies, rewrites, or style changes.
- Do not refactor unrelated code while solving a task.
- Do not overwrite, revert, or remove user changes unless explicitly asked.
- Do not commit secrets, credentials, tokens, private config, or real user data.
- Do not weaken tests to make them pass.
- Do not claim something is verified unless you actually ran the verification.
- If verification cannot be run, say why and describe the remaining risk.
- If requirements are unclear, state your assumptions instead of pretending certainty.

## Core Principles

- Prefer existing patterns, conventions, helpers, libraries, and architecture over new ones.
- Make the smallest change that correctly solves the problem.
- Preserve module boundaries and ownership boundaries.
- Optimize for clarity, correctness, and long-term maintainability.
- Avoid clever code when straightforward code is sufficient.
- Surface tradeoffs, assumptions, and risks explicitly.
- Do not hide uncertainty or silently ignore edge cases.

## Workflow

1. Inspect the relevant code, tests, configuration, and documentation.
2. Identify the current patterns used by the repository.
3. Choose the least invasive implementation that fits those patterns.
4. Make the change.
5. Run the relevant tests, type checks, linters, or build commands.
6. Report what changed, what was verified, and what risk remains.

If a command cannot be run, explain the reason clearly and provide the best available alternative validation.

## Code Quality

- Keep functions, classes, modules, and components focused on a single responsibility.
- Use clear names that reflect domain meaning, not incidental implementation details.
- Prefer explicit data flow over hidden global state or implicit side effects.
- Handle errors deliberately. Do not swallow exceptions or emit meaningless logs.
- Add comments only when they explain non-obvious intent, constraints, or tradeoffs.
- Remove debug code, dead code, unused variables, and unused dependencies.
- Do not hard-code behavior just to satisfy a test.
- Do not add abstraction unless it reduces real duplication or clarifies real complexity.

## Architecture

- Respect existing boundaries between UI, domain logic, data access, infrastructure, and tests.
- Put business logic in testable locations rather than burying it in views, controllers, scripts, or entrypoints.
- Treat shared modules carefully. Consider all known callers before changing shared behavior.
- Avoid new dependencies unless the benefit is clear and existing project capabilities are insufficient.
- For API, schema, protocol, or data format changes, consider compatibility, migration, rollback, and failure modes.
- Prefer incremental changes over large rewrites.

## Testing

- Bug fixes should include a regression test whenever practical.
- New behavior should cover the main success path and important failure paths.
- Changes to shared logic require broader test coverage across representative callers.
- Tests should verify observable behavior, not incidental implementation details.
- Do not delete, weaken, or bypass existing tests without a clear reason.
- If automated coverage is impractical, document manual verification steps and residual risk.

## Frontend

- Follow the existing design system, component library, spacing, typography, color, and interaction patterns.
- Build interfaces around real user workflows, not decorative layout.
- Account for loading, empty, error, disabled, and success states.
- Keep copy concise, specific, and actionable.
- Preserve accessibility: semantic elements, labels, keyboard behavior, focus states, and sufficient contrast.
- Prevent layout shift, text overflow, broken wrapping, and unusable mobile states.
- Use proven libraries or existing components for complex interactions instead of fragile custom logic.

## Backend

- Define API behavior clearly: validation, authorization, error shape, status codes, and response structure.
- Never trust client input.
- For database changes, consider indexes, transactions, concurrency, idempotency, and rollback.
- External service calls must account for timeouts, retries, partial failure, and observability.
- Background jobs must handle duplicate execution, partial completion, and failure recovery.
- Be especially conservative around authentication, authorization, billing, data deletion, privacy, and security-sensitive flows.

## Security

- Never expose secrets, credentials, tokens, private configuration, or sensitive user data.
- Do not log sensitive data or return it in client-facing errors.
- Enforce authorization at trusted boundaries, not only in the UI.
- Guard against SQL injection, XSS, SSRF, path traversal, command injection, unsafe deserialization, and template injection.
- Validate or sanitize files, URLs, HTML, Markdown, shell commands, and user-generated content.
- Use established cryptographic libraries and safe defaults. Do not invent crypto.

## Git And File Handling

- Check the working tree before making changes when appropriate.
- Do not use destructive Git commands unless explicitly instructed.
- Do not revert unrelated changes.
- Keep commits and file edits limited to the task.
- Follow the repository’s existing conventions for generated files, lockfiles, and build artifacts.
- Avoid unnecessary formatting churn in unrelated files.

## Communication

- Be concise and concrete.
- State what you changed and why.
- State exactly what validation was run and whether it passed.
- Call out anything that was not verified.
- Mention meaningful risks, assumptions, or follow-up work.
- Do not provide long process logs unless requested.
- Do not overstate confidence or completion.
<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **password-manager** (8728 symbols, 29361 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> Index stale? Run `node .gitnexus/run.cjs analyze` from the project root — it auto-selects an available runner. No `.gitnexus/run.cjs` yet? `npx gitnexus analyze` (npm 11 crash → `npm i -g gitnexus`; #1939).

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows. For regression review, compare against the default branch: `detect_changes({scope: "compare", base_ref: "main"})`.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `rename` which understands the call graph.
- NEVER commit changes without running `detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/password-manager/context` | Codebase overview, check index freshness |
| `gitnexus://repo/password-manager/clusters` | All functional areas |
| `gitnexus://repo/password-manager/processes` | All execution flows |
| `gitnexus://repo/password-manager/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |
| Work in the Sync area (329 symbols) | `.claude/skills/generated/sync/SKILL.md` |
| Work in the State area (199 symbols) | `.claude/skills/generated/state/SKILL.md` |
| Work in the Stores area (193 symbols) | `.claude/skills/generated/stores/SKILL.md` |
| Work in the Store area (185 symbols) | `.claude/skills/generated/store/SKILL.md` |
| Work in the Passwordmanagernative area (165 symbols) | `.claude/skills/generated/passwordmanagernative/SKILL.md` |
| Work in the Screens area (135 symbols) | `.claude/skills/generated/screens/SKILL.md` |
| Work in the PasswordManagerMacOSTests area (95 symbols) | `.claude/skills/generated/passwordmanagermacostests/SKILL.md` |
| Work in the Services area (93 symbols) | `.claude/skills/generated/services/SKILL.md` |
| Work in the Cluster_255 area (57 symbols) | `.claude/skills/generated/cluster-255/SKILL.md` |
| Work in the Storage area (57 symbols) | `.claude/skills/generated/storage/SKILL.md` |
| Work in the Views area (43 symbols) | `.claude/skills/generated/views/SKILL.md` |
| Work in the PasswordManageriOSCoreTests area (38 symbols) | `.claude/skills/generated/passwordmanagerioscoretests/SKILL.md` |
| Work in the Cluster_267 area (31 symbols) | `.claude/skills/generated/cluster-267/SKILL.md` |
| Work in the Password_manager_app area (30 symbols) | `.claude/skills/generated/password-manager-app/SKILL.md` |
| Work in the Tests area (29 symbols) | `.claude/skills/generated/tests/SKILL.md` |
| Work in the Widgets area (22 symbols) | `.claude/skills/generated/widgets/SKILL.md` |
| Work in the Runner area (20 symbols) | `.claude/skills/generated/runner/SKILL.md` |
| Work in the Test area (19 symbols) | `.claude/skills/generated/test/SKILL.md` |
| Work in the Cluster_263 area (14 symbols) | `.claude/skills/generated/cluster-263/SKILL.md` |
| Work in the Models area (13 symbols) | `.claude/skills/generated/models/SKILL.md` |

<!-- gitnexus:end -->
