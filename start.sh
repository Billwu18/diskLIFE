#!/bin/sh
# diskLIFE Linux boot loader. ASCII only. All real work happens in engine/launch.js.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
NODE=${DISKLIFE_NODE:-}
if [ -z "$NODE" ]; then
  if command -v node >/dev/null 2>&1; then NODE=node
  elif command -v nodejs >/dev/null 2>&1; then NODE=nodejs
  fi
fi
if [ -z "$NODE" ]; then
  echo "  ERROR E04: cannot find the Node.js runtime (needed by DeepSeek Harness)." >&2
  echo "  What to do: install Node.js, or set DISKLIFE_NODE to the node executable." >&2
  exit 1
fi
exec "$NODE" "$ROOT/engine/launch.js" --disc-root "$ROOT" "$@"
