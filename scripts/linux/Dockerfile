# Build image for `make linux-build` / `make linux-test`: the official Swift
# toolchain plus the system SQLite headers PlanMeterCore links against,
# python3 for the tests' fake Codex CLI, rsync to mirror the read-only
# source into the build volume, and curl for the planmeterd smoke run.
FROM swift:6.2-noble
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends curl libsqlite3-dev python3 rsync \
    && rm -rf /var/lib/apt/lists/*
