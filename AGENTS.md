# Project Instructions for AI Agents

## General
- Prefer Xcode mcp tools over make/xcodebuild/xcrun/tuist.
- Prefer the codebase memory MCP graph tools for code discovery before grep/file search: use `codebase-memory` skill.
- Respect warnings from compiler, linter and documentation compiler, and fix them when building code.
- No warnings are allowed in ANY target: app, WalletKit, unit tests and UI tests, macOS and iOS. Any build or test run can produce compiler or SwiftLint warnings, so after EVERY build and test run read the full warning list (`GetBuildLog` with `severity: warning`, no glob or pattern filter, as globs match task names and hide issues) for every scheme you touched, and fix every warning, including pre-existing ones. Cross-check changed files with `mise x swiftlint -- swiftlint lint --quiet --config .swiftlint.yml <files>`. Never report a build as clean without having checked.
- To examine animations from a screen recording, extract frames with `Scripts/video_frames.swift <video.mp4> [every-n-frames] [out-dir]` and view the PNGs.
- Be as succinct and concise as possible in decisions logs and documentation you produce, including source code comments. Don't overexplain.
## Memory & System Constraints
- You are working in a codebase that uses Architectural Decision Records (ADRs).
- Your shared memory resides in the `Docs/Decisions/` folder.

## Decision Log Workflow
1. **Context Check:** On every run or multi-hour milestone initialization, parse all entries under `Docs/Decisions/` to ensure your proposed code changes do not contradict previous architectural agreements.
2. **Logging Protocol:** When introducing major logic shifts, database schema changes, or external service integrations, you must document your reasoning.
3. **Execution Delivery:**
   - Utilize `/plan` mode before executing long-horizon tasks.
   - Build an `Implement.md` runbook if requested, but always output the finalized technical trade-offs to `Docs/Decisions/ADR-[ID].md` using the project's formatting template.
   - Update `Docs/Decisions/` continuously as items are shipped.
## Swift Code Style
- Write  `guard/if ... else { return/throw/break/continue }` in 3 lines so that return from scope is on its own line.
- Sort methods, types, enum cases and other unordered entities alphabetically where possible.
- Use `.style()` modifier for fonts, sizes and colors in SwiftUI.
- Prefer `case let .foo(bar)` to `case .foo(let bar)`.
- Omit `return` in one-liners wherever possible.
- Use `whateverId`, not `whateverID` when naming identifier properties.
- Use `.asJSONString()`/`.encoded()`/`.decoded()` from Codable+Extensions.swift for JSON (de-)serialization.

## Design
- Use the Penpot MCP server of the local Penpot instance (http://localhost:9001, MCP at http://localhost:4401/mcp), not design.penpot.app.
- All template icons in Penpot are magenta to make non-colored images visible early.
- Screens (`Screens / *` pages) are composed only of component instances from the `Components` page; no raw texts, icons or shapes. Missing control → add a component first.
- Never scale icon instances. Need another size → add it as an icon component (e.g. `trezor40`) to the `Icons` board on `Foundations` and use that.
- After editing designs, clean up every touched Penpot page: no overlapping top-level boards or components (re-pack the layout), and check for overlapping siblings inside screens.
- Every component has Mac and iOS variants (`Platform` property).
- Components use only colors, fonts, sizes and other values from the `Foundations` page, linked (library colors/typographies/tokens), not hardcoded.

## Commit messages

Before writing a message, inspect the staged diff and relevant context. Describe only changes included in the commit. Follow explicit repository conventions when they differ from the defaults below.

- Separate the subject and body with one blank line.
- Aim for a subject of 50 characters or fewer; stay within 72.
- Start the subject with a capital letter.
- Omit the trailing period.
- Use an imperative verb: “Add”, “Fix”, “Remove”, or “Simplify”.
- Wrap body prose at 72 characters.
- Explain the problem, resulting behavior, and reason for the change. Include meaningful trade-offs or consequences; avoid narrating code.
- Don't add co-authored by (agent name) notice.

Omit the body when the subject provides sufficient context. Avoid vague subjects such as “Update code” or “Fix issues”.

Never invent motivation, issue references, or test results. Include validation claims only when verified. Put relevant issue references at the bottom.

If the subject is difficult to summarize, check whether the commit combines unrelated changes.

Example:

```
Prevent duplicate transfer submissions

Repeated taps could submit a transfer more than once while the
initial request was pending. Disable submission until it completes
so each pending transfer produces a single request.
```

