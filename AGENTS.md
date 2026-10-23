# Project Instructions for AI Agents

## General
- Prefer Xcode mcp tools over make/xcodebuild/xcrun/tuist.
- Prefer the codebase memory MCP graph tools for code discovery before grep/file search: use `codebase-memory` skill.
- Respect warnings from compiler, linter and documentation compiler, and fix them when building code.
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
- Sort methods, types, enum cases and other unordered entities alphabetycally where possible.
- Use `.style()` modifier for fonts, sizes and colors in SwiftUI.
- Prefer `case let .foo(bar)` to `case .foo(let bar)`.
- Omit `return` in one-liners wherever possible.
- Use `whateverId`, not `whateverID` when naming identifier properties.
- Use `.asJSONString()`/`.encoded()`/`.decoded()` from Codable+Extensions.swift for JSON (de-)serialization.

## Design
- Use Penpot MCP server at https://design.penpot.app/mcp/stream?userToken=eyJhbGciOiJBMjU2S1ciLCJlbmMiOiJBMjU2R0NNIn0.KLj0WBlQKiGZwyQ6M3U53Ujc2LFe57QoVKsr8qYSULdNCy7eTRpOTg.AyqJTCwVaCphNIoX.-HMuE_5pkl1FwgP9Cpr3aeTTihSJqU9kkxRCrO8th4If7O_imsbwA-RY4uEvxpBGhOqrYU8dnZ8kjmfQI-oBI0xst1aknudsVI5RsiHQhfZ0QN9_PBNVFwAxgT9gYcw9yY31EvKVRxc-z7XzimLdMkYe6j-6tjLF2_YxwltMdzXCSvCGErLWRoEyGJUykuEckimzK9T7Rsspu-HlyL5N8FQ.e4t7y0SxHhAUjLAF9rPfIg
- All template icons in Penpot are magenta to make non-colored images visible early.

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

