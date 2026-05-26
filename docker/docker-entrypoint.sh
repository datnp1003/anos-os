#!/bin/sh
# 🦾 Anos Container Entrypoint (POSIX sh, Alpine-compatible)
set -e

echo "🦾 Anos Container Starting..."

# Start daemon in background
anosd &
ANOSD_PID=$!

# Wait for socket
i=0
while [ $i -lt 30 ]; do
    [ -S /tmp/anos.sock ] && break
    sleep 0.2
    i=$((i + 1))
done

echo "🦾 Anos ready — daemon PID $ANOSD_PID"

# Keep alive
wait $ANOSD_PID
