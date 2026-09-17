# Codex Agent Project Instructions

## General
- Prefer Xcode mcp over make/xcodebuild
- Prefer codebase-memory-mcp to files search
- Be as succinct and concise as possible in decisions logs and other documentation you produce. Don't overexplain.
## Memory & System Constraints
- You are working in a codebase that uses Architectural Decision Records (ADRs).
- Your shared memory resides in the `docs/decisions/` folder.

## Decision Log Workflow
1. **Context Check:** On every run or multi-hour milestone initialization, parse all entries under `docs/decisions/` to ensure your proposed code changes do not contradict previous architectural agreements.
2. **Logging Protocol:** When introducing major logic shifts, database schema changes, or external service integrations, you must document your reasoning.
3. **Execution Delivery:**
   - Utilize `/plan` mode before executing long-horizon tasks.
   - Build an `Implement.md` runbook if requested, but always output the finalized technical trade-offs to `docs/decisions/ADR-[ID].md` using the project's formatting template.
   - Update `docs/decisions/` continuously as items are shipped.
