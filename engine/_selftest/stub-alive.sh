#!/bin/sh
# Long-lived fake dsh for the self-test: prints a ready URL, then sleeps ~60s, so the
# single-instance lock (E10) can be exercised.
echo "dsh web: http://127.0.0.1:34568/?token=stub-alive"
sleep 60
