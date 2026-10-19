# Build image for `make linux-build` / `make linux-test`: the official Swift
# toolchain plus the system SQLite headers PlanMeterCore links against,
# python3 for the tests' fake Codex CLI, and rsync to mirror the read-only
# source into the build volume.
FROM swift:6.2-noble
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends libsqlite3-dev python3 rsync \
    && rm -rf /var/lib/apt/lists/*
