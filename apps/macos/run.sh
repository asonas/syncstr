#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
  echo "Usage: sh apps/macos/run.sh [path/to/Syncstr.app]" >&2
  exit 1
fi

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
app=${1:-"$script_dir/.build/Syncstr.app"}
case "$app" in
  /*) ;;
  *) app="$PWD/$app" ;;
esac
if [ ! -x "$app/Contents/MacOS/Syncstr" ]; then
  echo "Build Syncstr first: $app" >&2
  exit 1
fi
app=$(CDPATH= cd -- "$app" && pwd -P)
case "$app" in
  */Syncstr.app) ;;
  *) echo "Expected a Syncstr.app bundle: $app" >&2; exit 1 ;;
esac

user_id=$(id -u)
lock="${TMPDIR:-/tmp}/syncstr-run-$user_id.lock"
if ! mkdir "$lock" 2>/dev/null; then
  echo "Another launch may be running; inspect the lock: $lock" >&2
  exit 1
fi
trap 'rmdir "$lock"' EXIT
trap 'exit 1' HUP INT TERM

syncstr_processes() {
  listing=$(ps -axo uid=,pid=,comm=) || return 1
  printf '%s\n' "$listing" | awk -v uid="$user_id" '
    $1 == uid && /\/Syncstr\.app\/Contents\/MacOS\/Syncstr$/ {
      pid = $2
      sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "")
      printf "%s\t%s\n", pid, $0
    }
  '
}

running=$(syncstr_processes)
if [ -n "$running" ]; then
  printf 'Stopping Syncstr (PID, executable):\n%s\n' "$running"
  printf '%s\n' "$running" | while IFS="$(printf '\t')" read -r pid executable; do
    env kill -TERM "$pid"
  done
fi

attempt=0
while [ -n "$running" ] && [ "$attempt" -lt 10 ]; do
  sleep 1
  running=$(syncstr_processes)
  attempt=$((attempt + 1))
done
if [ -n "$running" ]; then
  printf 'Syncstr did not exit; no app was launched:\n%s\n' "$running" >&2
  exit 1
fi

open -n "$app"
attempt=0
while [ "$attempt" -lt 10 ]; do
  running=$(syncstr_processes)
  if [ -n "$running" ]; then
    paths=$(printf '%s\n' "$running" | cut -f 2-)
    if [ "$paths" = "$app/Contents/MacOS/Syncstr" ]; then
      printf 'Running one Syncstr (PID, executable):\n%s\n' "$running"
      exit 0
    fi
    printf 'Unexpected Syncstr processes after launch:\n%s\n' "$running" >&2
    exit 1
  fi
  sleep 1
  attempt=$((attempt + 1))
done
echo "Syncstr did not start: $app" >&2
exit 1
