#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
image="${1:-syncstr-headless:check}"
mkdir -p .build
fixture_root="$(cd ../apps/macos/Tests/Fixtures && pwd)"
check_root="$(mktemp -d "$PWD/.build/container-check.XXXXXX")"
container="syncstr-container-check-$$"
container_user="$(id -u):$(id -g)"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  command rm -rf "$check_root"
}
trap cleanup EXIT HUP INT TERM
mkdir "$check_root/identity" "$check_root/data"
docker run --rm --user "$container_user" --volume "$check_root/identity:/identity:rw" \
  "$image" init --identity /identity --host localhost
docker run --detach --name "$container" --user "$container_user" --read-only \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --volume "$check_root/identity:/identity:ro" --volume "$check_root/data:/data:rw" \
  --volume "$fixture_root:/fixtures:ro" "$image" >/dev/null
node_cli() {
  docker exec "$container" /usr/local/bin/syncstr-headless "$@" \
    --url https://localhost:8443 --cert /identity/tls.crt --token-file /identity/token
}
attempt=0
until node_cli catalog > "$check_root/catalog.json" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 20 ]; then docker logs "$container"; exit 1; fi
  sleep 0.5
done
node_cli upload --file /fixtures/untagged.mp3 --title 'Container fixture' > "$check_root/upload.json"
track_id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["track"]["id"])' < "$check_root/upload.json")"
node_cli upload --file /fixtures/untagged.mp3 --title 'Retry title' > "$check_root/retry.json"
cmp "$check_root/upload.json" "$check_root/retry.json"
docker stop --time 10 "$container" >/dev/null
[ "$(docker inspect --format '{{.State.ExitCode}}' "$container")" = 0 ]
docker start "$container" >/dev/null
attempt=0
until node_cli catalog > "$check_root/catalog.json" 2>/dev/null; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 20 ]; then docker logs "$container"; exit 1; fi
  sleep 0.5
done
node_cli download --id "$track_id" --output /data/received.mp3
cmp "$fixture_root/untagged.mp3" "$check_root/data/received.mp3"
node_cli catalog > "$check_root/catalog.json"
python3 -c 'import json,sys; assert len(json.load(sys.stdin)["entries"]) == 1' < "$check_root/catalog.json"
docker exec "$container" /bin/test -s /usr/share/syncstr/licenses/inventory.json
printf '%s\n' 'Container upload, retry, graceful restart, verified download, and license bundle: PASS'
