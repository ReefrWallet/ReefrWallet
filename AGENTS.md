# Project Instructions for AI Agents

## General
- Prefer Xcode mcp tools over make/xcodebuild/xcrun/tuist.
- Prefer codebase-memory skill to files search.
- Respect warnings and fix them when building code.
- Be as succinct and concise as possible in decisions logs and other documentation you produce. Don't overexplain.
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
- Write  `guard ... else { return/throw/break/continue }` in 3 lines so that return from scope is on its own line.
- Sort methods, types, enum cases and other unordered entities alphabetycally where possible.
- Use `.style()` modifier for fonts, sizes and colors in SwiftUI
