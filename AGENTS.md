# Project Instructions for AI Agents

## General
- Prefer Xcode mcp tools over make/xcodebuild/xcrun/tuist.
- Prefer the codebase memory MCP graph tools for code discovery before grep/file search: use `codebase-memory` skill.
- Respect warnings and fix them when building code.
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
- iPhone: https://www.figma.com/design/BVzlL19u6OSqBXMERw1U46/Reefr-Wallet-%E2%80%93-Transaction-List-Entries?node-id=0-1
- iPad: https://www.figma.com/design/BVzlL19u6OSqBXMERw1U46/Reefr-Wallet-%E2%80%93-Transaction-List-Entries?node-id=21-250
- macOS: https://www.figma.com/design/BVzlL19u6OSqBXMERw1U46/Reefr-Wallet-%E2%80%93-Transaction-List-Entries?node-id=4-76

