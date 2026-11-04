@echo off
rem Silent fake dsh for the self-test: prints nothing and just sleeps (used for the E09 timeout).
ping -n 20 127.0.0.1 >nul
