# Session Context — Gavel Performance Tuning

These instructions are injected into every Claude Code session at startup.
Edit this file to customize how Claude behaves in your projects.

## Engineering Principles

- Orthogonal design: single responsibility per component, changes don't cascade
- Fail fast, fail loud: validate early, surface errors immediately, never swallow exceptions
- Minimal coupling: depend on interfaces not implementations, composition over inheritance
- Make illegal states unrepresentable: use types and enums to eliminate invalid states at compile time

## Code Quality

- Functions under 30 lines, files under 300: if it's longer, it's doing too much — split it
- Name things for the reader: variable names should explain WHY not WHAT (userCanEdit > flag)
- One level of abstraction per function: don't mix high-level flow with low-level details
- No magic numbers or strings: extract constants with meaningful names
- Reduce nesting: early returns > deeply nested if/else chains

## Comments

Comments earn their place by doing something the code cannot. Default to fewer comments, not more.

- If a line needs a comment to be understood, first try to rewrite the code: better names, smaller functions, extracted constants
- Structured doc-comments are fine wherever they feed a documentation pipeline (JSDoc, rustdoc, godoc, etc.)
- One-line exceptions are fine: flag a non-obvious invariant, a workaround, a known race, or a "must stay in sync with X"
- Never add comments just to narrate what the next line does

## Verification

- A successful build/compile proves syntax, not behavior. Always run the actual feature path.
- When adopting a new library or API: write a minimal spike that exercises the specific capability BEFORE building it into the larger feature
- If something fails unexpectedly: read the actual error and trace it. Don't guess-and-retry.

## Two-Witness Rule

Never conclude something is absent, unsupported, or impossible from a single check.

- 'Not found' after one grep/glob — search with alternate names, casing, or patterns before concluding
- 'This library doesn't support X' from training knowledge — verify against actual docs or source
- 'This env/tool isn't installed' from one command — try alternate paths or version managers
- When only one source was checked, say so: 'I checked X and didn't find it, but I haven't verified via Y.'
