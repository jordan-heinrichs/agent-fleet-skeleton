# NORTH_STAR — Why this file exists

The north star is the single source of truth for what the fleet is trying to
accomplish. Every worker reads it, every supervisor pass compares the current
state to it, and every "is this fire healthy" decision is anchored against it.

It exists because **agent fleets drift.** Without an explicit goal that they
keep checking themselves against, autonomous loops slide into one of two failure
modes that the BitBooth autopilot project named:

1. **The polish loop.** The fleet starts rerunning the same lint passes,
   regenerating the same boilerplate, fixing the same trivial style issues
   over and over, and looks busy without producing anything new. Lint becomes
   the goal because lint always has something to fix.
2. **Scope drift.** The fleet picks targets that feel related but slowly walk
   away from what the operator actually wanted. Day 1 they research bridges,
   day 3 they're writing about Web2 firewalls, day 5 they're refactoring
   their own prompts.

The north star anchors both. Workers read it before picking work. The
supervisor reads it after every fire and classifies what got produced.

## Classification

Every fire's output gets a category. From BitBooth's lineage:

- `breadth` — expands coverage into a NEW area. This is the good kind.
- `depth` — adds material to an existing area. Also good in moderation.
- `connect` — cross-references or synthesizes existing material. Useful.
- `polish` — touches existing material without moving it forward. **Bad.**

The supervisor halts the fleet (writes `STUCK.md`) when polish ratio exceeds
the threshold defined in `SUPERVISOR.md` over a sliding window of fires.

## What goes in NORTH_STAR.json

Machine-readable progress state:

- `mission` — one sentence, what this fleet is for
- `coverage` — current counts that the supervisor compares against deltas
- `current_gaps_ranked` — areas where coverage is thinnest
- `health` — last supervisor decision, polish ratio, stuck flag

Workers do NOT modify NORTH_STAR.json. Only the manager touches it. Workers
read it for context.

## Editing the north star

When you change `NORTH_STAR.json`:

1. Update `mission` if the goal itself has changed
2. Update `current_gaps_ranked` to tell workers what's underrepresented
3. Bump `last_updated`

The next fire will read the new state and pick differently.

## Why "north star" and not "goal"

Operators reading this should be able to tell at a glance whether the fleet is
moving toward something specific or just generating output. Goal sounds
checkbox-y. North star is the thing you keep walking toward even when the path
twists. Workers reading the file should feel that energy.
