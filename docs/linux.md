# diskLIFE on Linux / 在 Linux 上跑 diskLIFE

> 状态：Linux 端口与 Windows 端口**并存**。Windows 侧仍是 PowerShell + IMAPI2；Linux 侧是纯
> Node.js（零 npm 依赖）+ 自带 ISO9660/Joliet 写入器。两边共用同一份光盘格式
> （[DISC-SPEC.md](DISC-SPEC.md)）与同一个人格房间布局。

---

## 1. 能做什么

| 能力 | Linux 实现 | 依赖 |
| --- | --- | --- |
| 光盘启动器（E01–E10） | `start.sh` → `engine/launch.js` | Node.js ≥ 18（dsh 本身就需要） |
| 打包光盘目录 | `tools/new-disc.js` | Node.js |
| 静态校验 | `tools/test-disc.js` | Node.js |
| 生成 ISO（ISO 9660 + Joliet） | `tools/new-iso.js` | 内置写入器，无需任何第三方工具 |
| 刻录 CD-R | `tools/burn-iso.js` | 可选：`wodim` / `cdrecord` / `cdrskin` / `growisofs` / `xorriso` |
| Studio（本地网页工作台） | `start-studio.sh` → `studio/server.js` | Node.js + 浏览器 |
| 插盘自启助手（可选） | `engine/tools/disc-watch.js` | Node.js；udisks2 事件 + XDG autostart，无需 root |
| 插件载荷重建 | `tools/new-profile-payload.js` | Node.js + 已登录的 dsh + 网络（仅重建时） |

刻录与守望者是可选能力：**没有光驱也能完整使用**（挂载 ISO 或直接对目录启动）。

---

## 2. 环境要求

| | |
| --- | --- |
| 系统 | Linux（x86_64 / arm64 均可） |
| 运行时 | DeepSeek Harness **0.2.x**，已安装并登录过一次（`dsh` 在 `PATH` 上） |
| Node.js | ≥ 18（`node` 或 `nodejs` 在 `PATH` 上；也可用 `DISKLIFE_NODE` 指定） |
| 可选 | 光驱 + `wodim`/`cdrecord`/`cdrskin`/`growisofs`/`xorriso`；`xdg-open` 用于自动开浏览器 |
| 空间 | 项目约 2 MB；每个房间几 MB（装插件更多） |

`engine/launch.js` 只接受 Linux（其他系统报 E05，提示在 Windows 上用 `start.cmd`）。
Node 是硬性依赖：`dsh` 本身就是 Node 程序，所以任何能跑 dsh 的机器都已经有 Node。

---

## 3. 五分钟上手（不需要光盘）

```sh
git clone <this repo> diskLIFE
cd diskLIFE

# 1) 用自带示例人设打一张盘（输出到 build/linux-disc）
node tools/new-disc.js --persona examples/sample-persona --out build/linux-disc

# 2) 校验（必需文件、清单哈希、pad.bin、start.sh、README 等）
node tools/test-disc.js --disc build/linux-disc

# 3) 直接从目录启动，不用刻盘
bash build/linux-disc/start.sh
#    或者：node build/linux-disc/engine/launch.js --disc-root build/linux-disc
```

启动器打印 URL / 房间 / 日志三行；要停就在终端 Ctrl+C 结束那个 node 进程（或在 DSH 控制台退出）。
房间（记忆、会话、设置）留在硬盘上。

想做自己的人设：

```sh
./start-studio.sh          # 自动打开 http://127.0.0.1:4791/
```

七步填完 → 导出人设 → 打包光盘 → 生成 ISO →（可选）刻录。产物落在 `persona/<slug>/`、
`build/<slug>/`、`build/*.iso`。

> 4791 被占用会自动顺延；已经有 Studio 在跑时不会起第二个，直接把浏览器指过去。

---

## 4. 光盘入口：`start.sh`

ISO 9660 / Joliet **不保存可执行位**，而且不少发行版会把可移动介质挂成 `noexec`。所以：

- 不要双击/直接执行 `start.sh`；用 **`bash /media/$USER/<盘>/start.sh`**（或
  `exec 前先 `shell` 打开）。启动器只是一个 Node 脚本，`node .../engine/launch.js` 永远可用。
- Linux 没有 AutoPlay：`autorun.inf` 是给 Windows 的，在 Linux 上不生效。想「插盘即启动」请安装
  可选守望者（见第 8 节）。
- 文件管理器里能直接双击 `start.sh` 的系统，如果提示「是否运行」，选择运行也可能被 `noexec` 拒绝；
  这时用 `bash` 方式最稳。

`start.sh` 的约定（与 [DISC-SPEC.md](DISC-SPEC.md) 一致）：POSIX sh、LF、无 BOM、纯 ASCII，
只负责找 `node` 并把参数转交给 `engine/launch.js`。找不到 Node 时报 E04 并提示安装或设置
`DISKLIFE_NODE`。

常用参数（与 Windows 启动器一一对应）：

```sh
bash start.sh --no-browser
bash start.sh --upgrade-persona
bash start.sh --home-root ~/personas
bash start.sh --dsh-path /usr/local/bin/dsh
bash start.sh --start-timeout-sec 90
```

环境变量：

| 变量 | 作用 |
| --- | --- |
| `DISKLIFE_NODE` | 指定 node 可执行文件（`start.sh` 用） |
| `DISCPERSONA_DSH` | 指定 dsh 可执行文件（优先级低于 `--dsh-path`） |
| `DISCPERSONA_SOURCE_HOME` | 搬凭据的「主 home」 |
| `DISCPERSONA_HOME` | 显式指定房间根目录（优先于自动推断） |
| `XDG_DATA_HOME` | 房间兜底位置：`$XDG_DATA_HOME/DiscPersona/personas` |
| `XDG_STATE_HOME` | 守望者日志：`$XDG_STATE_HOME/disklife/disc-watch.log` |

---

## 5. 房间（数据）放在哪

与 Windows 同构，只是路径换成 XDG：

```
<房间根>/personas/<discID>/
  home/            = DSH_HOME（profiles/web、storages、sessions、.credentials.yaml）
  workspace/       dsh 工作目录；memories/ 首启播种
  logs/            launch-*.log（保留最近 10 个）
  state.json       discID / name / bootCount / lastUrl ...
  persona/         首启从盘上固化；之后以房间为准
```

房间根的解析顺序：

1. `--home-root <目录>`；
2. 环境变量 `DISCPERSONA_HOME`；
3. **跟着 dsh 安装位置**：若 `dsh` 在 `npm-global` / `node_modules` / `.bin` / `npm` /
   `pnpm-global` / `yarn` 目录下，就往上退一级；该目录必须可写，且不能是系统目录
   （`/usr`、`/bin`、`/etc`、`~/.config`、`~/.cache` 等）；
4. 兜底：`${XDG_DATA_HOME:-~/.local/share}/DiscPersona/personas`。

每次启动都会在日志里写一行 `Room root: <path> (<source>)`，方便确认。默认情况下：

- dsh 装在 `~/.local/bin/dsh`（npm 全局）→ 房间在 `~/.local/DiscPersona/personas/<discID>`；
- dsh 装在不适合当根目录的位置（如 `/usr/bin`）→ 房间在
  `~/.local/share/DiscPersona/personas/<discID>`。

`discID` 仍是 `pad.bin` 的 SHA-256 前 16 位：同一张盘永远同一间房，换一张盘就是另一间房。
把整个 `personas/<discID>` 目录复制走就是完整备份/迁移。

---

## 6. 凭据从哪来

启动器**只搬 DeepSeek 相关条目**，原样复制、从不解析或打印值。dsh 0.2.x 的两种登录形态都接受：

1. **账号登录**：`records` 下的 `deepseek-account-platform/default` + `/device`，加上
   `refs.DEEPSEEK_API_KEY`；
2. **浏览器会话登录**（本机 `~/.dsh` 常见形态）：`records` 下的
   `client-connection/browser-session`，加上 `refs.DEEPSEEK_API_KEY` 和/或
   `refs.DEEPSEEK_PLATFORM_TOKEN`。

其他 refs（例如飞书/同步 token）不会复制，房间里的 `.credentials.yaml` 一律 0600。
来源目录顺序：`DISCPERSONA_SOURCE_HOME` > `DSH_HOME` > `~/.dsh` > `$XDG_DATA_HOME/dsh`。
两种形态都不满足 → E07，提示先在本机正常登录一次 dsh。

---

## 7. ISO 与刻录

生成 ISO（ISO 9660 + Joliet，中文文件名不丢；生成后会**回读校验**每个文件与大小）：

```sh
node tools/new-iso.js --source build/linux-disc --out build/linux-disc.iso
node tools/new-iso.js --source build/linux-disc --out build/disc.iso --volume-label ARIS --force
```

卷标规则：Joliet 卷描述用 UCS-2BE，支持中文等 Unicode（最多 16 个字符，默认取 `persona/meta.json` 的
`nameJp` / `name`）；ISO 9660 主卷描述只能是 ASCII，会自动回退成 `DISCPERSONA`。桌面环境（GNOME/udisks）
读的是 Joliet 卷标，所以中文人设名会原样显示。

始终使用内置的纯 JS 写入器：无需 root、无需第三方工具，写入后逐文件回读校验（Joliet 名称 + SHA-256）。
内置写入器不写 Rock Ridge，因此 ISO 里没有 Unix 权限位；这不影响使用（用 `bash start.sh` 启动）。
（`xorriso`/`genisoimage` 不会被用于生成 ISO，因为它们会额外写入 Rock Ridge 条目，改变盘上树形与自校验基准。）

刻录（可选；没有光驱/工具时会给明确的 `BURN_FAIL`）：

```sh
node tools/burn-iso.js --list-drives
node tools/burn-iso.js --iso-path build/linux-disc.iso --drive /dev/sr0 --test-only
node tools/burn-iso.js --iso-path build/linux-disc.iso --drive /dev/sr0 --eject
```

写入器自动探测 `xorriso` → `cdrskin` → `cdrecord` → `wodim` → `growisofs`（`xorriso -as cdrecord`）。
`--test-only` 会真正用写入器打开设备（不是只看 `/dev/sr0` 是否存在），打不开就报 B06，不会假报成功。
错误码与 Windows 一致：B01 没有该设备 / B02 设备不能刻 / B03 没有介质或介质不支持 /
B04 介质非空白 / B05 ISO 不存在或为空 / B06 打不开或工具缺失 / B07 写入失败 / B08 回读仍为空。
刻完可回读校验：

```sh
node tools/test-disc.js --disc /media/$USER/<盘名>
```

---

## 8. 插盘自启助手：Linux 上的 AutoPlay 等价物（可选）

Linux **没有** Windows 那种 AutoPlay：光盘上的 `autorun.inf` 不会被读取，GNOME/udisks 也刻意不允许从
可移动介质直接执行程序（安全设计）。要接近「插入光盘 → 弹窗 → 启动」，需要一个常驻在**用户会话**里的小
程序；本仓库自带 `engine/tools/disc-watch.js`，不需要 root：

```sh
# 前台运行，插盘时弹「启动 / 稍后」
node engine/tools/disc-watch.js

# 登录自启（XDG autostart）；之后每次插入 diskLIFE 盘都会弹窗
node engine/tools/disc-watch.js --install
node engine/tools/disc-watch.js --uninstall

# 不弹窗，插入即启动
node engine/tools/disc-watch.js --auto
# 先发桌面通知（带「启动」按钮），不支持时退回弹窗
node engine/tools/disc-watch.js --notify
# 不自动挂载，只响应桌面已经挂好的盘
node engine/tools/disc-watch.js --no-mount
# 强制只用挂载轮询（默认优先用 udisks2 D-Bus 事件）
node engine/tools/disc-watch.js --poll

# 只检测目录，不启动/prompt
node engine/tools/disc-watch.js --test-root build/linux-disc --dry-run
```

行为：

- **事件驱动**：优先用 udisks2 的 D-Bus 信号（`gdbus monitor --system --dest org.freedesktop.UDisks2`，
  没有 gdbus 时退到 `busctl monitor`）触发扫描；另保留 10 秒一次的低频轮询兜底。没有事件源或加
  `--poll` 时退回 2.5 秒轮询。这样不依赖 `/proc/mounts` 轮询频率，插盘后通常 1 秒内响应。
- 如果盘还没有被桌面挂载，会用 `udisksctl mount -b /dev/srN` 自动挂载（无 root；失败写日志，
  不影响桌面自己的挂载）。
- 识别依据是盘根同时有 `pad.bin` 与 `persona/persona.yml`；从 `persona/meta.json` 取人设名，弹窗文案形如
  「检测到 diskLIFE 光盘：蓝色大肥鱼 (v1.0.0) — 启动 / 稍后」。
- 选「启动」→ 以 `--no-wait` 拉起 `engine/launch.js` 并打开浏览器；选「稍后」→ 本次不再询问，拔出重插会再问。
- 同一张盘被挂载两次（例如 loop + 光驱）只会唤醒一次：按 `discID = sha256(pad.bin)[0:16]` 去重。
- 默认优先使用**本仓库当前的** `engine/launch.js`，回退到盘上的 `engine/launch.js`。这样用早期版本
  烧的盘也能享受到启动器修复（不必重刻）；想完全模拟裸机行为时加 `--disc-engine`。
- 单实例锁 `${XDG_STATE_HOME:-~/.local/state}/disklife/disc-watch.pid`，登录自启和手动启动不会起两份。
- 日志：`${XDG_STATE_HOME:-~/.local/state}/disklife/disc-watch.log`。

### 8.1 在 Studio 里一键配置

Linux 版 Studio 的「07 出厂」页底部有一块 **Linux：插盘自动启动** 面板（仅 Linux 服务器会出现）：

- 自动识别发行版（`/etc/os-release`）与包管理器（pacman / apt / dnf / zypper / apk / xbps / nix）；
- 显示依赖状态（udisks2、glib2/gdbus、zenity/kdialog、xdg-utils）以及事件源；
- 缺依赖时给出**对应发行版的安装命令**（复制即可）；
- 「启用登录自启 / 关闭登录自启」直接调用 `disc-watch.js --install/--uninstall`；
- 「现在启动 / 停止守望者」立即起停，不需要等下次登录。

对应 HTTP 接口：`GET /api/linux/integration`、`POST /api/linux/autostart`
（`{action: install|uninstall|start|stop|status}`），同样只监听 127.0.0.1。

> 更「零常驻」的方案是 udev 规则 + systemd 用户单元，在设备插入事件里触发；这需要一次性 root 安装，
> 而且不同发行版的 systemd/udev 组合行为有差异，本仓库不自动安装。日常使用 `--install` 的登录自启
> + udisks2 事件已经足够。Linux 没有 AutoPlay 是系统安全策略，不是本项目的缺失；守望者不会绕过挂载策略，
> 也不会以 root 运行。

---

## 9. Studio（Linux）

```sh
./start-studio.sh
# 或：node studio/server.js --port 4791 --no-browser
```

- 只监听 `127.0.0.1`；Host / Origin / `Sec-Fetch-Site` 校验与 Windows 版一致。
- 打包调用 `tools/new-disc.js`，ISO 调用 `tools/new-iso.js`，刻录调用 `tools/burn-iso.js`；
  光驱列表来自 `/dev/sr*` 与 `/sys/block/*/device/model`。
- 「打开目录」用 `xdg-open`。
- AI 起草默认关闭；开启后服务端从 `DSH_STUDIO_KEY` 或本机 `.credentials.yaml` 读 key，
  不会把 key 返回给浏览器。
- 其余接口、错误码（S01–S99）与 [studio.md](studio.md) 完全一致。

---

## 10. 与 Windows 版的差异

| 方面 | Windows | Linux |
| --- | --- | --- |
| 入口 | `start.cmd`（AutoPlay 可选） | `start.sh`；没有 AutoPlay |
| 启动器 | PowerShell 5.1 | Node.js（`engine/launch.js`） |
| 房间兜底 | `%LOCALAPPDATA%\DiscPersona\personas` | `${XDG_DATA_HOME:-~/.local/share}/DiscPersona/personas` |
| 光驱列表 | IMAPI2 / WMI | `/dev/sr*` + `/sys` |
| 刻录 | IMAPI2 | `xorriso`/`cdrskin`/`wodim`/`cdrecord`/`growisofs`（可选） |
| ISO | IMAPI2（ISO9660 + Joliet） | 内置 ISO9660 + Joliet 写入器（始终使用） |
| 守望者 | WMI 卷事件 + 启动项 | `/proc/mounts` 轮询 + XDG autostart |
| 浏览器 | 默认浏览器 | `xdg-open` |
| 错误码 | E01–E10 / B01–B08 / I01–I04 / PL00–PL05 | 相同 |

`autorun.inf`、`start.cmd` 仍然会写入光盘，所以**同一张盘在 Windows 上也能用**；反过来，
Windows 打的盘如果带了 `engine/launch.js` 与 `start.sh`，在 Linux 上也能用（本仓库的
`tools/new-disc.js` 一定会带上两者）。

---

## 11. 测试

```sh
# 启动器回归（stub dsh，不联网、不需要光驱）：17 项
node engine/_selftest/run-tests.js

# 工具链 + Studio 集成测试
node --test tests/

# 手工走一遍
node tools/new-disc.js --persona examples/sample-persona --out build/linux-disc
node tools/test-disc.js --disc build/linux-disc
node tools/new-iso.js --source build/linux-disc --out build/linux-disc.iso
```

CI 在 `ubuntu-latest` 上跑同一组命令（见 `.github/workflows/checks.yml` 的 `linux` job）。

---

## 12. 排障

| 现象 | 原因 / 处理 |
| --- | --- |
| `E04` 找不到 dsh | `dsh` 不在 `PATH`；或 `dsh --version` 不能跑。设置 `DISCPERSONA_DSH` 或 `--dsh-path`。 |
| `start.sh` 报找不到 node | 安装 Node.js ≥ 18，或 `DISKLIFE_NODE=/path/to/node bash start.sh`。 |
| `E05` | 在非 Linux 系统上运行了 `engine/launch.js`；Windows 请用 `start.cmd`。 |
| `E06` | 房间目录不可写、磁盘满、路径被文件占住。检查权限/空间，或用 `--home-root`。 |
| `E07` | 本机没有可用的 DeepSeek 登录；先正常登录一次 dsh，或设置 `DISCPERSONA_SOURCE_HOME`。 |
| `E08` | `persona.yml` 里没有 `system_prompt: |` 块，或文件不是 UTF-8。 |
| `E09` | 60 秒内没等到就绪 URL；看 `logs/stdout-*.log` 最后 15 行。 |
| `E10` | 这个房间已经有一个实例在跑（退出码 0，会打开已有地址）。 |
| `ISO_FAIL I05` | 写出的 ISO 回读校验不匹配；删掉旧 ISO 后重试（`--force`），仍失败请附上输出反馈。 |
| `BURN_FAIL B06` | 没装写入工具（装 `cdrtools`/`cdrskin`/`xorriso`），或写入器打不开设备（USB 掉线/供电不足/权限）。先看 `journalctl -k \| tail -30` 有没有反复 `USB disconnect` / `reset`；换 USB 口（优先后置口、别用 hub）、换线、用双头供电线。 |
| 插盘没反应 | 盘没有被自动挂载，或挂载点不满足 `pad.bin` + `persona/persona.yml`；先手动挂载再试。 |
| `bash start.sh` 正常但双击不行 | 介质被挂成 `noexec`（常见于 udisks 默认策略）；用 `bash` 启动，或挂载时加 `exec`。 |
