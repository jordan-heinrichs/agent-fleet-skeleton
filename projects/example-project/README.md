# projects/example-project/

This is a placeholder project. Replace the contents with whatever you actually
want the fleet to work on.

## Layout each project follows

```
projects/<your-project>/
├── README.md            # what this project is
├── PROJECT_TARGETS.md   # the input the workers pick from
├── findings/            # researcher output lands here
└── synthesis/           # synthesizer output lands here
```

The `findings/` and `synthesis/` directories don't need to exist yet — the
worker creates them on its first run.

## To switch projects

Edit `.env`:

```
ACTIVE_PROJECT=<your-project-directory-name>
```

Then `docker compose up -d --build` to rebuild and restart.

## To run multiple projects from one fleet

Out of the box the manager only runs one project at a time. The simplest way
to run several is to run multiple fleets (one docker-compose stack per
project, each pointing at its own Redis instance via different `JOB_QUEUE` and
`RESULT_QUEUE` env names).

A more sophisticated version puts a project picker in the manager so each
tick rotates through projects too. That's a small change to
`docker/manager/entrypoint.sh` — pick a project from a list, then pick roles
within that project. Left as an exercise for whoever extends this.
