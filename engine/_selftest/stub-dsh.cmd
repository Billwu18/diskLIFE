@echo off
rem Fake dsh for the DiscPersona self-test: prints a ready URL and stays alive for a while,
rem which is what the single-instance lock test needs.
@if "%DP_STUB_SLEEP%"=="" (set "DP_STUB_SLEEP=15")
@echo dsh web: http://127.0.0.1:34567/?token=stub-selftest
ping -n %DP_STUB_SLEEP% 127.0.0.1 >nul
