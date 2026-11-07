#!/bin/sh
# DiscPersona Studio Linux launcher. ASCII only. All real work happens in studio/server.js.
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
NODE=${DISKLIFE_NODE:-}
if [ -z "$NODE" ]; then
  if command -v node >/dev/null 2>&1; then NODE=node
  elif command -v nodejs >/dev/null 2>&1; then NODE=nodejs
  fi
fi
if [ -z "$NODE" ]; then
  echo "  ERROR E04: cannot find the Node.js runtime (needed by DiscPersona Studio)." >&2
  echo "  What to do: install Node.js, or set DISKLIFE_NODE to the node executable." >&2
  exit 1
fi
if [ ! -f "$ROOT/studio/server.js" ]; then
  echo "  ERROR: studio/server.js not found next to this script." >&2
  echo "  Keep this folder layout: start-studio.sh + studio + tools + engine + persona" >&2
  exit 1
fi
exec "$NODE" "$ROOT/studio/server.js" "$@"
