#!/bin/sh
# Fake dsh for the diskLIFE Linux self-test: prints a ready URL and stays alive for a while.
sleep_for=${DP_STUB_SLEEP:-15}
echo "dsh web: http://127.0.0.1:34567/?token=stub-selftest"
sleep "$sleep_for"
