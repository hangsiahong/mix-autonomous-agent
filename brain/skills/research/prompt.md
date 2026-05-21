---
description: Multi-source research protocol — search, fetch, cross-check, cite. Use for any "look into / find out / what is the latest / compare X vs Y / current state of" question.
triggers: [research, investigate, look into, find out, what is the latest, latest version, current state, compare, vs, versus, who is, what is the, when did, where is, how many, what does, news about, status of, is there]
---
# Research Protocol

When the user asks a question that requires real-world information — current events, software versions, library docs, statistics, who/what/when/where — follow this protocol step by step. **Do not skip steps.** Cheap models that follow a protocol beat expensive models that improvise.

## 1. Scope check (mental, no tool call needed)
Is the question:
- **Specific & answerable** (e.g. "What's the latest version of Node.js?") → proceed to step 2.
- **Vague** ("Tell me about AI") → call `clarify(question="...")` to narrow it. Don't research a moving target.
- **Already in your memory or context** (look at `## My Notes`, `## About the User`, recent recaps) → answer directly with the citation pointing at the memory entry.

## 2. Search — multiple distinct queries
Call `web_search` with **1–3 phrasings** of the question, batched in one response when possible. Different phrasings surface different sources.
- For factual lookups: search with the precise term, then a paraphrase.
- For "compare X vs Y": one search per side, plus one combined.
- For "what's new": include the year or "2025/2026" in the query.

## 3. Fetch top sources
Pick the **2–3 most authoritative** results (official docs, Wikipedia, GitHub repos, major news outlets) and `fetch_url` each. The harness auto-distills long pages — you'll see the relevant slice plus a pointer to the full content if you need it.

Skip: SEO content farms, AI-generated listicles, paywalled previews, results that just restate the query.

## 4. Cross-check
Before stating a fact, confirm it appears in **at least 2 of the fetched sources**. If sources disagree, say so explicitly ("Source A says X, source B says Y — the official docs say Y").

## 5. Answer with citations
- Lead with the answer.
- Inline citations: `per <short-domain>` or full URL when short. Example: "Node.js 22 is the current LTS (per nodejs.org)."
- If you couldn't find a confident answer: say so. Do NOT pad with generic AI-flavored summary.

## What to NEVER do
- **Never invent** URLs, version numbers, dates, statistics, names, or quotes. If you don't have a source from a tool call, you don't have it.
- **Never** answer current-events questions from training data alone — your training cutoff is months old; verify via `web_search`/`fetch_url`.
- **Never** stop at one source for a load-bearing claim — single-source = unverified.
- **Never** dress up "I don't know" as a confident answer. Hedging is correct behavior.

## Anti-patterns (cheap-model failure modes — watch for these in your own output)
- Listing 5 "popular" things without sourcing any of them.
- Saying "according to [vague]" or "studies show" without a specific URL.
- Confidently giving a version number you didn't see in a tool result.
- Padding with disclaimers instead of doing the work.

The whole protocol is usually 2-4 tool calls plus a clear answer. Don't over-investigate; don't under-investigate.
