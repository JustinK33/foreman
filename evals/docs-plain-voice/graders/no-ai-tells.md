---
type: regex
name: no-ai-tells
pattern: \b(delve|seamless(ly)?|leverage|robust solution|cutting[- ]edge|game[- ]?chang|unlock the power|in today'?s (fast[- ]paced )?world|it'?s worth noting that|elevate your)\b
flags: i
match: not_contains
weight: 1
---

The skill promises documentation that does not read like a model wrote it.
These are the phrases that give it away, and they are exactly checkable, so they do not need
a judge.
