---
name: docs
description: Use when the user asks to write, update, or improve documentation, READMEs, API docs, docstrings, ADRs, or runbooks. Also trigger on "/foreman:docs" or "/docs".
argument-hint: "[what to document]"
---

# Documentation

Write the doc a tired engineer at 2am would actually be grateful for, not the one that looks thorough in a demo.

## Pick the right artifact for the job

- **README** - what the project is, how to run it, how to contribute. Not a full manual.
- **API reference** - generated from code where possible (docstrings, OpenAPI/JSDoc/type hints); hand-written only for the parts generation can't cover (why, not just what).
- **Architecture Decision Record (ADR)** - one decision, one file, immutable once accepted. Captures context, the decision, and the tradeoff, not a running log.
- **Runbook** - operational: what breaks, how to tell, what to do about it. Written for someone paged at 3am with no context, not for someone doing a leisurely read.
- **Inline comments/docstrings** - explain *why*, not *what*. If the code needs a comment to explain what it does, the fix is usually clearer code, not a longer comment.

Don't produce a doc type nobody asked for just because it's available; a project doesn't need an ADR for every function.

## Structure that scales across companies (the actually common pattern)

1. **One-sentence purpose** - what this is and why it exists, before anything else.
2. **Quick start** - the fastest path to a working state. Copy-pasteable commands, not prose describing commands.
3. **Core concepts / how it works** - only the mental model needed to use it correctly, not the full internals.
4. **Reference detail** - options, parameters, edge cases. Scannable, not narrative.
5. **Troubleshooting / FAQ** - the things people actually get stuck on, sourced from real questions if you have them, not invented ones.
6. **Lessons learned / gotchas** - what surprised the people who built it. This is the section people skip writing and then regret.

Cut any section that would be empty or filler; a shorter doc that's all signal beats a template fully filled in with padding.

## Writing style: sound like an engineer, not a language model

- Say the thing directly. Cut "It's important to note that," "In today's fast-paced development environment," and any sentence that exists to sound thorough rather than to inform.
- Vary sentence length. A string of uniform, medium-length sentences is the most reliable tell of generated prose; short sentences next to longer ones read human.
- Use concrete specifics over vague superlatives: "handles 10k requests/sec" beats "highly performant and scalable." Name the actual number, tool, or version instead of a generic adjective.
- Skip the reflexive "Additionally," "Furthermore," "Moreover" at paragraph starts. Most of the time the transition isn't needed at all; when it is, plain "Also" or nothing reads better.
- Don't manufacture a rule of three ("fast, reliable, and scalable") unless there are genuinely three things worth naming. Two is fine. Five is fine.
- Write from what actually happened or what the code actually does, not generic best-practice language layered on top. "We tried Redis first and hit eviction issues under load, moved to Postgres" beats "caching strategies were evaluated for optimal performance."
- Skip the summary paragraph that just restates the doc in different words. If the doc needs restating to be understood, the doc needs editing instead.
- No em dashes standing in for a comma or period; use the comma, period, or a plain word instead.

## Scaffolding practice

When starting docs for a new project or module, scaffold the skeleton (headers, one-line placeholders for each section) and fill in only what's known now; mark unknowns explicitly (`TODO: confirm rate limit`) rather than inventing plausible-sounding content to fill the gap. A doc with an honest gap is more trustworthy than one that's confidently wrong.

## Keeping docs from rotting

Docs that describe behavior belong as close to the code as the tooling allows (docstrings, comments near the decision) so they change in the same diff as the code. A doc that lives far from what it describes is a doc that goes stale; flag this when reviewing where a doc is being added.
