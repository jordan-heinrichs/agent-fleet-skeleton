# web3-security pack

A real, filled-in example pack — a Web3 security research fleet. Use it as-is,
or as the reference for authoring your own topic pack.

## What it does

Four specialist roles (incident-hunter, audit-excavator, archetype-writer,
primitive-specialist) mine current security research into a structured library
under `output/`. Web grounding is ON, so workers fetch real sources (ranked
toward arxiv, audit firms, official docs) and cite only what actually exists.

## Run it

```bash
# in .env:
ACTIVE_PACK=web3-security
WEB_GROUNDING is read from the pack (on)
# bring up with the grounding profile so SearXNG starts:
docker compose --profile grounding up -d --build
```

## Why it's a good template

It shows every pack lever in use: multiple roles with distinct `**Search:**`
queries and `**Output:**` dirs, web grounding enabled, and a curated
`SEARCH_PREFERRED_DOMAINS` list that lifts source quality for the topic. Clone
the folder, swap the domain, and you have a fleet for anything.
