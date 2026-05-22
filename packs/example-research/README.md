# example-research pack

The default pack — a generic research domain. It does nothing useful until you
make it yours, which is the point: it's the template every other pack copies.

## Anatomy

```
packs/example-research/
  pack.env      config (name, output dir, web-grounding toggle, search prefs)
  ROLES.md      specialist roles (each with a **Search:** query + **Output:** dir)
  TARGETS.md    the domain's sources/targets
  output/       where workers write (created on first run)
  README.md     this file
```

## Make your own pack in 3 steps

```bash
cp -r packs/example-research packs/my-topic
# 1. edit packs/my-topic/ROLES.md     — your specialist roles + search queries
# 2. edit packs/my-topic/TARGETS.md   — your sources
# 3. set ACTIVE_PACK=my-topic in .env, then: docker compose up -d --build
```

That's it. The orchestrator, workers, manager, Redis cache, provider adapters,
and (optional) web grounding are all domain-agnostic — they read whatever pack
`ACTIVE_PACK` points at.

See `packs/web3-security/` for a real, filled-in example.
