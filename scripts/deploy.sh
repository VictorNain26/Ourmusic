#!/usr/bin/env bash
# Promotes origin/master onto the running stack when it moves. Driven by
# aubesonore-deploy.timer; safe to run by hand.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$HOME/radio/aubesonore}"
cd "$REPO_DIR"

current=$(git rev-parse HEAD)
target=$(git ls-remote origin refs/heads/master | cut -f1)

if [ -z "$target" ]; then
  echo "cannot reach origin, leaving $current in place"
  exit 1
fi

if [ "$current" = "$target" ]; then
  exit 0
fi

echo "deploying ${current:0:8} -> ${target:0:8}"
git fetch --quiet origin master

# drizzle push is manual and can drop columns, so a schema change must not ride
# in on an unattended deploy: the new code would boot against the old tables.
if ! git diff --quiet "$current" "$target" -- apps/backend/src/db/schema.ts; then
  echo "schema.ts changed — apply 'bun db:push' by hand, then: systemctl --user start aubesonore-deploy"
  exit 1
fi

git merge --ff-only "$target"
docker compose up -d --build --remove-orphans

deadline=$((SECONDS + 300))
while true; do
  pending=""
  for cid in $(docker compose ps -q); do
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid")
    [ -z "$health" ] && continue
    [ "$health" = "healthy" ] && continue
    pending="$pending $(docker inspect -f '{{.Name}}' "$cid")=$health"
  done

  if [ -z "$pending" ]; then
    echo "deployed ${target:0:8}, all healthchecks green"
    break
  fi

  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "deployed ${target:0:8} but unhealthy after 300s:$pending"
    exit 1
  fi

  sleep 5
done

docker image prune -f --filter "until=72h" >/dev/null
