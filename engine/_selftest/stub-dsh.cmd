@echo off
rem DiscPersona 自测用假 dsh：打印就绪地址后睡一会儿（保持进程存活，便于测单实例锁）。
@if "%DP_STUB_SLEEP%"=="" (set "DP_STUB_SLEEP=15")
@echo dsh web: http://127.0.0.1:34567/?token=stub-selftest
ping -n %DP_STUB_SLEEP% 127.0.0.1 >nul
