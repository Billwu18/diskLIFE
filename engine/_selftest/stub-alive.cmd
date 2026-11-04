@echo off
rem 自测用「长命」假 dsh：打印就绪地址后 sleep 约 60 秒，用来验证单实例锁（E10）。
@echo dsh web: http://127.0.0.1:34568/?token=stub-alive
ping -n 61 127.0.0.1 >nul
