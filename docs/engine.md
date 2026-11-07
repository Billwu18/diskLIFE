# DiscPersona 启动引擎（engine/）

把一张只读光盘变成「人设的物理载体」：插入光盘 → 双击根目录 `start.cmd` → 在硬盘上的独立 home 里拉起一个与主 DSH **完全隔离**的 DeepSeek Harness Web 实例，并加载光盘上的人设。

本期是「身份凭证」模式：拔盘后人格 home 仍在，不做严格钥匙。

---

## 1. 调用方式

`start.cmd`（由别人维护）只需要这一行：

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<disc>\engine\launch.ps1" -DiscRoot "<disc>"
```

`launch.ps1` 的可选参数（排障 / 自测用，正常使用不需要）：

| 参数 | 说明 |
| --- | --- |
| `-DshPath <path>` | 指定 `dsh.cmd` 全路径；等价环境变量 `DISCPERSONA_DSH` |
| `-HomeRoot <dir>` | 人格 home 的**父目录**（默认 `<dsh 安装根>\DiscPersona\personas`，见下文「房间放哪」） |
| `-StartTimeoutSec <n>` | 等 dsh 打印就绪 URL 的最大秒数，默认 60 |
| `-NoBrowser` | 不自动打开浏览器（自测用） |
| `-UpgradePersona` | 用盘上人设覆盖房间人设（先备份成 `persona.bak-<时间戳>`） |
| `-NoWait` | 启动完成后立刻返回，不等按键（自测 / 光驱守望者用） |

启动成功后**默认不退出**：控制台会停在「按任意键关闭这个窗口；关掉窗口不会停止实例」，
等用户按键。`stdout` 被重定向（管道、脚本捕获）时自动跳过等待，避免自动化挂死。

环境变量：

| 变量 | 作用 |
| --- | --- |
| `DISCPERSONA_DSH` | 指定 dsh 可执行文件（优先级低于 `-DshPath`） |
| `DISCPERSONA_SOURCE_HOME` | 指定「主 home」（搬凭据的来源） |
| `DISCPERSONA_HOME` | 显式指定房间根目录（优先于自动推断） |
| `LOCALAPPDATA` | 只在推断不到 dsh 安装位置时兜底 |

---

## 2. 运行时目录（全部在硬盘上）

```
<房间根>\personas\<discID>\
├─ home\                        = DSH_HOME（profiles\、storages\、sessions\、.credentials.yaml）
│  ├─ persona.patch.yml         = 每次启动根据光盘人设重写
│  ├─ user.patch.yml            = 可选，用户自己放的额外 patch（先于 persona 应用）
│  ├─ AGENTS.md                 = 首启从光盘复制一次，之后不再覆盖
│  └─ .lock                     = 单实例锁（PID + 进程启动时间）
├─ workspace\                   = dsh 进程工作目录（sandbox 的 workspaceRoot 落在人格 home 内）
│  └─ memories\                 = 首启从 persona\seed 复制（她最初的记忆）
├─ logs\                        = launch-<yyyyMMdd-HHmmss>.log + stdout-/stderr-/bootstrap-*.log
└─ state.json                   = {discID,name,personaVersion,bootCount,firstBootAt,lastBootAt,lastPort,lastUrl}
```

`discID` = `pad.bin` 的 SHA-256 十六进制**前 16 位小写**。同一张盘永远落在同一个目录，换盘就是另一间房。

`logs\launch-*.log` 只保留最近 **10** 个，更旧的自动删除。

### 2.1 房间放哪：跟着 dsh 的安装位置

房间根（`<房间根>\personas`）的选择顺序：

| 顺序 | 来源 | 本机实际值 |
| --- | --- | --- |
| 1 | `-HomeRoot <dir>` 参数 | 测试/排障用 |
| 2 | 环境变量 `DISCPERSONA_HOME` | 便携部署用 |
| 3 | **自动推断**：找 dsh 可执行文件 → 若在 `npm-global` / `node_modules` / `.bin` / `npm` / `pnpm-global` / `yarn` 目录下就往上退一级 → 该目录必须是可写的「安装根」 | `E:\dsh` → `E:\dsh\DiscPersona\personas` |
| 4 | 兜底 `%LOCALAPPDATA%\DiscPersona\personas` | 只在推断不到时用 |

「安装根」不合格的情况会被跳过并继续往下找：`%SystemRoot%`、`%ProgramFiles%`、
`%ProgramFiles(x86)%`、`%APPDATA%`、`%LOCALAPPDATA%` 及其子目录，或不可写的目录。

为什么这样定：用户希望「dsh 装在哪，人设就存在哪」，而不是默认塞进 C 盘用户目录。
日志里每次都会写一行来源，方便确认：

```
房间根目录：E:\dsh\DiscPersona\personas（跟着 dsh 安装位置（E:\dsh））
```

---

## 3. 启动流程

1. **环境检查**：非 Windows 或 PowerShell < 5.1 → E05。
2. **光盘完整性**：根目录必须有 `persona\persona.yml`、`persona\meta.json`、`pad.bin`；缺哪个报哪个 → E01。
3. **算 discID**：读 `pad.bin`（读失败 → E02），取 SHA-256 前 16 位。
4. **manifest 校验**：`.discpersona\manifest.json` 存在则逐文件比对 SHA-256，失配 → E03 并给出相对路径；manifest 缺失只写警告，不算错。
5. **准备人格目录**：建 `home\ logs\ workspace\`，写探针文件验证真实可写 → 失败 E06（报完整路径）。
6. **读人设（房间优先）**：见第 3.1 节——房间里有 `persona\persona.yml` 就用房间的，没有就先把盘上的整份固化进房间；
   再从生效的那份 `persona.yml` 取 `system_prompt: |` 块标量（解析不出 → E08），从 `meta.json` 取 `name` / `version`
   （缺省「爱丽丝」/「1.0.0」）。
7. **单实例**：读 `home\.lock`，PID 存活且启动时间对得上 → 直接用 `state.json` 的 `lastUrl` 打开浏览器，打印「这个孩子已经在醒着了：<url>」，**退出码 0**（E10）。
8. **首启准备**（仅当 `home\profiles\web` 不存在）：
   - 若光盘有 `.discpersona\payload\profile-web\`（兼容 `profile-persona`、`payload\` 平铺）→ 整目录复制过去，并记下插件名（`payload.json`）；
   - 否则让 dsh 自己冷启动一次，把 shipped profile `web` 落到 `home\profiles\web` 后立刻杀掉（见第 4 节）；
   - 搬凭据（见第 5 节），失败 → E07；
   - 复制 `persona\seed\` → `workspace\memories\`；复制 `persona\AGENTS.md` → `home\AGENTS.md`（只首启，不覆盖）。
9. **钉定工作区 + 同步人设卡**（每次启动，见 3.3 / 3.4）：把 `storages\workspace.json` 改成「房间里这一间房」，
   把 dafeiyu 的人设卡改成这张盘的人设。两件事都失败只写警告，不阻塞启动。
10. **生成 patch**：重写 `home\persona.patch.yml`；若存在 `home\user.patch.yml`，参数顺序为 **先 user 后 persona**，保证人设最后生效。
11. **起进程 + 等就绪**：`--profile web --patch <...> --port <p> --no-open`，`DSH_HOME` 指到人格 home，工作目录 `workspace\`；stdout/stderr 重定向到 `logs\`。轮询 stdout 里 `http://127.0.0.1:<port>/?token=<token>`：
    - 拿到 → 打开浏览器，打印 `diskLIFE started` / `Persona:` / `URL:` / `Room:` 四行（英文），退出码 0；
    - 超时 → 杀进程树，E09，并打印 stdout 最后 15 行。

### 3.1 人设从哪来：固化 / 房间优先 / 升级

「盘上的人设」只在**首次启动那一刻**是权威，之后房间里的那份才是。

| 情况 | 行为 |
| --- | --- |
| 房间没有 `persona\persona.yml`（首次 / 删过） | 把盘上 `persona\` **整份**复制到 `...\personas\<discID>\persona\`（含 `avatar`、`card.json`、`seed\`），然后以房间为准 |
| 房间有人设 | 直接读房间那份；盘上那份只用于比对版本，**从不静默覆盖** |
| 盘上 `meta.json.version` 比房间高 | 只记 `state.json.pendingPersonaUpgrade = {from, to}` 并在日志提示；要真升级得加 `-UpgradePersona` |
| `-UpgradePersona` | 先把房间 `persona\` 复制成 `persona.bak-<时间戳>`，再删掉、由「固化」重建为盘上版本；成功后 `pendingPersonaUpgrade` 自然消失 |
| 固化失败（只读 / 权限） | 降级直接用盘上那份，`state.personaSource = disc`，只写警告不阻塞启动 |

`state.json` 里对应三个字段：`personaSource`（`room` / `disc`）、`personaVersion`（实际生效的版本）、
`pendingPersonaUpgrade`（只在「盘比房间新」时出现）。

版本比较用 `Compare-DPVersionText`：按 `.` `-` `_` `+` 切段，两边都是数字则数值比，否则序数比，
缺段按 0（所以 `1.10.0 > 1.9.0`，`1.2.1 > 1.2`）。备份目录不会自动清理，需要时手动删。

---


### 3.2 预装插件载荷（payload）

盘上 `.discpersona\payload\profile-web\` 是一份**打包时**准备好的 `profiles\web`（`package.json` + `cordis.yml` + `node_modules`），
由 `tools\New-ProfilePayload.ps1` 按预设生成：临时 home 里 `dsh plugin add <预设的包>` → 剥掉 `.cache` / `.pnpm-store` → 写 `payload.json`（含 `preset`、`dshVersion`、`plugins[]`）。

四组预设（`New-Disc.ps1 -PayloadPreset`，Studio 的「07 出厂」页同款）：

| preset | 插件 | 体积 |
| --- | --- | --- |
| `none` | —— | 0（不写 `.discpersona\payload\`） |
| `comfort` | `dsh-soul-md`、`dsh-persona-dafeiyu` | ~0.49 MB |
| `token` | `dsh-context-compress`、`dsh-faster-compress`、`dsh-read-image-compress` | ~0.58 MB |
| `full` | 以上五个 | ~0.87 MB |

`none` 不打载荷，引擎走冷启动生成 vanilla profile；`state.json.payloadPreset` 记 `none`。

首启时整份复制到 `home\profiles\web`，于是这个人一睁眼就有记忆工具和人设库，不需要联网装插件。

**失败回退**（启动循环里的两趟）：

```
for ($pass = 1; $pass -le 2; $pass++)
  带 payload 起 dsh → 等到 URL 就成功
  若失败：删 profiles\web → 冷启生成 vanilla profile → payloadUsedNow = false → 重试一次
```

日志里会出现「带插件载荷启动失败，丢弃预打包 profile，回退纯人设重试一次」。人设本身走 patch，不依赖插件，
所以回退后人还是那个人，只是少了 `memory_*` 工具。`state.json.payloadPlugins` 记录载荷里包含的插件
（回退时它仍然记录这份列表，但本次实际没有加载——以日志里是否出现「Plugin payload:」为准），
`state.json.payloadPreset` 记录用的是哪组预设（`none` / `comfort` / `token` / `full`），回退时预设保留。

### 3.3 同步人设卡（dsh-persona-dafeiyu）

`dsh-persona-dafeiyu` 在没有用户选择时会**默认注入它内置的人设**（`dafeiyu` = 大肥鱼）。这会在 system prompt 里和盘上人设打架：
实测模型 reasoning 会写「The persona card in the system prompt says 大肥鱼」。

所以每次启动都会重写 `<home>\storages\dsh-persona-dafeiyu\personas.json`：

```json
{ "current": "discpersona",
  "disabled": ["dafeiyu", "acha"],
  "personas": { "discpersona": { "name": "<盘上名字>", "text": "<盘上 system_prompt>" } } }
```

- 用户自己导入的卡**保留**，只把 `current` 指到 `discpersona`、把内置两条禁掉。
- `text` 每次按生效的 `persona.yml` 重写 —— 改房间人设重启，卡也跟着变。
- 插件不在（回退成纯人设）时跳过，不会因为缺目录而报错。

### 3.4 钉定工作区（不与主 DSH 共用「文档」）

dsh 的默认工作区是 `%USERPROFILE%\Documents\deepseek-harness\default-workspace`，**与 cwd 无关**。
不改的话人格实例和主实例会共用同一个目录：记忆、AGENTS.md、随手写的文件全串台。

每次启动重写 `<home>\storages\workspace.json`（storage v2）：

```json
{ "unit": {"name": "workspace", "version": 2},
  "global": {"initialized": true, "defaultWorkspaceId": "<guid>",
             "workspaceIds": ["<guid>"], "archivedSessionIds": [], "pinnedSessionIds": []},
  "tables": {"workspaces": {"<guid>": {"path": "<房间>\workspace",
                                        "title": "天童爱丽丝的房间",
                                        "sessionIds": [], "createdAt": "...", "updatedAt": "..."}}} }
```

两个坑都踩过：

- **不能用 `ConvertTo-Json` 生成这份文件**：PS 5.1 把空数组序列化成 `{}`，dsh 的 zod 校验直接失败 ——
  `DomainError: stored record ... does not match its schema` / `ZodError: sessionIds expected array, received object`，
  前端表现为**永远停在「正在加载工作区…」**，picker 里只剩「添加工作区…」。
- 因此 `Sync-DPWorkspace` 用 `ConvertTo-DPJsonString` 手工拼 JSON，`sessionIds` 显式输出 `[]`。
  同 path 的旧记录会复用 guid 与已有 `sessionIds`。

工作区 title 是 `<人设名>的房间`，所以侧栏显示「天童爱丽丝的房间」，不是「默认工作区」。

---

### 3.5 世界书（lorebook.json）

`persona\lorebook.json` 的条目每次启动都会拼到人设正文末尾：

```
## 世界书（设定，不是台词）
下面这些是你所在世界的事实。它们始终成立，但不要主动背诵，也不要逐条复述。

### <comment 或 "keys 用 / 拼起来">
<content>
```

- **全部条目都拼**：`--patch` 通道没有关键词检索能力，只拼 `constant` 会让大部分世界书悄悄消失。
- 排序：`constant: true` 优先，其次按 `insertion_order`（缺省用数组下标）。
- 上限 **6000 字**，超出的条目在日志里报「略过 N 条」，不会静默丢弃。
- 日志形如 `Lorebook: merged 3 entries (~114 chars), cap 6000 chars`；文件不存在或 JSON 坏掉只记警告，不影响启动。
- 世界书取自**当前生效的那份人设**（房间优先），所以改房间里的 `lorebook.json` 重启即生效。

## 4. 为什么不脚手架（`--from-default-profile`）

最初的设计是首启用 `dsh --profile web --from-default-profile web` 生成 profile。实测**不可行**：

```
Error: dsh: profile "web" names shipped profile "web" and cannot be a custom profile target;
omit --from-default-profile to use it
```

（exit 1。换成自定义 profile 名可以建目录，但生成的 `dependencies: {}` 没有安装依赖，
启动时报 `Missing services: webServer`，exit 1，`profiles\<name>` 里没有 `node_modules`。）

**结论：不脚手架。** 固定使用 shipped profile `web`：

- 首启检测仍然是「`home\profiles\web` 不存在」；
- 不存在时，用 `--port 0` 冷启动一次真实 dsh（5–6 秒），它会在 `$DSH_HOME` 下自动生成
  `profiles\web`、`storages\`、`.credentials.yaml`、`.anonymous-user-id`，并打印就绪 URL；
  拿到 URL 后立即 `taskkill /T /F`，然后才导入凭据、正式启动。

这样 profile 一定与当前安装的 dsh 版本匹配，也不会把「依赖没装」的坑带进光盘。

---

## 5. 凭据搬运（不解析、不打印密钥）

来源目录优先级：`DISCPERSONA_SOURCE_HOME` > `E:\dsh\dsh-data` > `%USERPROFILE%\.dsh`。

从源 `.credentials.yaml` **原样搬 DeepSeek 相关条目**到 `home\.credentials.yaml`。dsh 0.2.x 有两种登录形态，
两种都接受：

1. **账号登录**：`records` 下的 `deepseek-account-platform/default` + `deepseek-account-platform/device`，
   以及 `refs.DEEPSEEK_API_KEY`；
2. **浏览器会话登录**（Linux 本机常见）：`records` 下的 `client-connection/browser-session`，以及
   `refs.DEEPSEEK_API_KEY` / `refs.DEEPSEEK_PLATFORM_TOKEN`。

其他 refs（飞书、同步 token 等）不复制；目标文件里已有的无关条目保持不动。房间 `.credentials.yaml`
在 Linux 上一律 0600（dsh 的 credentials 插件会拒绝 0644）。
搬运按「2 空格缩进切块」进行，值一个字节都不改写，也从不输出到控制台或日志。

失败语义：

- 两种登录形态都不满足（没有账号记录、也没有 browser-session + key/token）→ E07
- 源目录不存在 / 读不了 → E07
- 源文件里缺上面任意一项 → E07（提示「请先在本机正常登录过一次 DSH」）
- 写入失败 → E06

---

## 6. manifest 规范形状

`packer` 产出的规范形状（`tools/_selftest/out-disc/.discpersona/manifest.json` 即此形状）：

```json
{
  "format": 1,
  "discID": "0123456789abcdef",
  "files": {
    "persona/persona.yml": "<sha256 hex>",
    "persona/meta.json": "<sha256 hex>",
    "pad.bin": "<sha256 hex>"
  }
}
```

校验时逐条比对；路径以 `/` 分隔，允许子目录。为兼容其它打包器，解析器同时接受：

- `{"files": [{"path": "...", "sha256": "..."}]}`
- `{"entries": [ ... ]}`、`{"manifest": [ ... ]}`、顶层数组
- 值写成 `{"sha256": "..."}` / `{"hash": "..."}` / 带 `sha256:` 前缀

manifest 本身读不出来 → E03（无法确认完整性）。没有 manifest → 只警告，继续启动。

---

## 7. 单实例锁与端口

- `home\.lock` 存 `{pid, startTicks, startedAt, port, host}`；`pid` 是 `cmd.exe` 包装进程（它存活期 == dsh 存活期）。
- 判定存活时同时比对进程启动时间（tolerance 2 秒），避免 PID 被系统复用造成假「已在运行」。
- 锁判定已在运行 → 打开 `state.json.lastUrl`，打印两行，**退出码 0**。
- 残留锁（进程已退出）→ 打警告、删锁、继续启动。
- 端口：优先 `state.json.lastPort`（用 `TcpClient` 探测是否被监听）；被占用或本次启动失败 → 回退 `--port 0` 重试一次。
- 读 dsh 的 stdout 时用 `FileShare.ReadWrite` 打开——cmd 的 `>` 重定向只给写句柄，普通 `ReadAllBytes` 会撞共享冲突（这曾导致每步白等 15 秒）。

---

## 8. 错误码与退出码

| 错误码 | 含义 | 退出码 | 何时出现 |
| --- | --- | --- | --- |
| E01 | 光盘不完整 | 1 | 缺 `persona\persona.yml` / `persona\meta.json` / `pad.bin` |
| E02 | pad.bin 读不了 | 1 | 光盘磨损、光驱读盘失败 |
| E03 | 文件被改动过 | 1 | manifest 失配 / 文件缺失 / manifest 本身坏了 |
| E04 | 找不到 dsh | 1 | PATH 上没有 dsh.cmd，也没设 `DISCPERSONA_DSH` |
| E05 | 环境不支持 | 1 | 非 Windows 或 PowerShell < 5.1（Linux 侧：非 Linux 或 Node 不可用） |
| E06 | home 写不进去 | 1 | 目录不可写、磁盘满、路径被文件占住 |
| E07 | 凭据缺失 | 1 | 主 home 不存在，或没有 `deepseek-account-platform/*` + `DEEPSEEK_API_KEY` |
| E08 | 人设文件解析失败 | 1 | 找不到 `system_prompt`，或文件读不出来 |
| E09 | 启动超时 | 1 | 60 秒内没等到就绪 URL（会附 stdout 最后 15 行） |
| E10 | 已在运行 | **0** | 已有一个实例活着，已为你打开它的地址 |
| E11 | 无法读取加密人设口令 | 1 | 加密盘首次启动但没有终端/Node/口令 |
| E12 | 口令错误或密文损坏 | 1 | `persona.sealed` 解不开 |

**E10 = 0 是有意的**：它不是失败，而是「已经开好了，我把浏览器叫出来了」。`start.cmd` 拿到 0 会直接关窗，
用户看到的是浏览器亮起来。只有 E01–E09 才是失败（退出码 1，`start.cmd` 会 `pause` 让用户看提示）。

所有失败都走同一个出口：中文一句话结论 + 「怎么办」一句 + 错误码。

---

## 9. 自测

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File engine\_selftest\run-tests.ps1
```

自测会造一张假光盘（含 `pad.bin`、`persona.yml`、`meta.json`、`manifest.json`、`seed\`、`AGENTS.md`）、
一个假主 home，并用 `engine\_selftest\` 下的三个 stub 代替真实 dsh：

| stub | 行为 |
| --- | --- |
| `stub-dsh.cmd` | 打印 `dsh web: http://127.0.0.1:34567/?token=stub-selftest`，睡约 15 秒 |
| `stub-alive.cmd` | 打印 `http://127.0.0.1:34568/?token=stub-alive`，睡约 60 秒（测单实例） |
| `stub-silent.cmd` | 什么都不打印，只睡（测 E09） |

覆盖 17 项断言：T1 首启（文案 / URL / patch 内容 / state.json / seed+AGENTS）、T2 E10、
T3 E01、T4 E03、T5 E07、T6 E08、T7 E04、T8 E09、T9 E06、
**T10 首次运行即固化**（房间有 `persona\`、`personaSource=room`）、
**T11 房间优先 + pending**（改房间生效、盘上高版本只记 `pendingPersonaUpgrade`）、
**T12 `-UpgradePersona`**（备份目录含旧正文、patch 换成盘上正文、版本升到 1.3.0、pending 清空）、
**T13 E07 后自愈**（首启失败、`profiles\web` 已被创建后，重跑仍会补导凭据并启动成功）、
**T14 pin 不被清空**（`workspace.json` 里的 `pinnedSessionIds` 在重启后仍保留）。
全部通过时退出码 0。

> 插件载荷与人设卡同步不在自测里（stub dsh 不产生这些文件），由端到端实测覆盖：
> `state.json.payloadPlugins`、`storages\dsh-persona-dafeiyu\personas.json` 两处；
> `storages\workspace.json` 由 T14 覆盖。

---

## 10. YAML 子集边界（已知限制）

`persona.yml` 用的是**极简子集解析器**，只保证覆盖人设文件最常见的写法：

支持：

- 顶部 `#` 注释、空行
- 顶层 `name:`、`version:` / `persona_version:` 标量
- `system_prompt:` 的 `|` 块标量（保留缩进与换行）、`>` 折叠标量、单行标量、单/双引号
- 块标量里出现比正文更浅的行即视为块结束

不支持（会按「取不到正文 → E08」或按字面处理）：

- 锚点 `&` / 别名 `*`、标签 `!!`、多文档 `---`
- 流式集合 `{...}` / `[...]`、`system_prompt` 作为嵌套子键（例如 `persona:\n  system_prompt:`）
- 块标量的缩进指示符（`|2`）与显式 chomping 标记（`|-`、`|+`）
- 制表符缩进（YAML 规范本身也禁止）

如果以后人设文件复杂到超集，建议直接改用 `js-yaml` 之类的实现，而不是继续加解析分支。

---

## 11. 其它实现细节 / 未尽事项

- 脚本必须是 **UTF-8 with BOM + CRLF**：PS 5.1 会按 ANSI 解码无 BOM 的 UTF-8，中文直接乱码。
  `engine\` 下所有 `.ps1` 已按此保存；`.cmd` 用 CRLF。
- 控制台统一 `[Console]::OutputEncoding = UTF8`。
- 依赖：只用 Windows PowerShell 5.1 自带功能（`TcpClient`、`Get-FileHash`、`ConvertFrom-Json`），**不装任何 npm 包 / 第三方模块**。
- 所有路径都用 `-LiteralPath` / 显式引号，支持中文与空格；脚本不 `cd`，相对路径都基于 `$PSScriptRoot`。
- 首启会多花约 5–6 秒（冷启动一次 dsh 生成 profile）。
- 目前不做「光盘是不是钥匙」的校验：拔盘后人格 home 仍在、仍可启动。
- `state.json` 里的 `firstBootAt` 只在首次写入，之后保留；`bootCount` 每次成功启动 +1。
- `-UpgradePersona` 产生的 `persona.bak-<时间戳>` 会一直留着（不自动清理），确认没问题后手动删。
- 升级检查发生在**单实例锁之前**：已在运行时的二次启动也会先做固化/升级判断，但不会重启进程。
- 浏览器打开失败不阻塞启动（只是没自动弹窗，地址仍打印在控制台与日志里）。

## 12. 健壮性审计与修复（2026-11-04）

三路只读审计（engine / tools+server / web）共报 3 条 P0、19 条 P1，已修完 P0 与本节列出的 P1。

### 12.1 已修的关键缺陷

| 缺陷 | 现场 | 修法 |
| --- | --- | --- |
| 首启失败后凭据永远补不回来 | `firstBoot` 只看 `profiles\web` 是否存在，而 payload 复制就会创建它；E07 之后重跑直接走 `else` | 抽出 `Initialize-DPPersonaAssets`（凭据 / seed / AGENTS 三步幂等），**每次启动**都调用 |
| E07 重试时工作区记录写不进去 | `storages\` 目录没人建，`WriteAllText` 抛错被吞，退回「文档」默认工作区（与主 DSH 串台） | `Write-DPTextFile` 写前 `New-Item -Force` 建父目录 |
| 单实例锁 TOCTOU | 先读锁（395 行）后写锁（823 行），中间几十秒 payload 复制 + bootstrap，并发双击起两个实例 | 残留锁清理后**立即**写锁（PID=启动器），最终成功后覆盖为 dsh 的 PID 与端口 |
| 人设卡只同步一次 | 同步条件 `if ($payloadUsedNow)`，改房间 `persona.yml` 后 patch 变了、卡片没变 | 改为每次启动都同步 |
| `pwsh` 下人设卡静默失效 | `start.cmd` 优先 `pwsh`，而 `JavaScriptSerializer` 依赖的 `System.Web.Extensions` 在 PS7 不存在 | `start.cmd` 改优先 `powershell.exe`，`pwsh` 只作兜底 |
| 空 `system_prompt: \|` 报 E09 | 只有「找不到键」才报 E08，全空白走到启动超时 | 空/全空白同样报 E08 |
| 进程已退出仍空等满超时 | `HasExited` 后只 `continue`，要等满 60 s | 无就绪地址时立即 `break`，E09 立刻返回 |
| 启动会清空 pin / 归档 | `workspace.json` 里 `archivedSessionIds` / `pinnedSessionIds` 硬编码 `[]` | 读旧记录时保留并写回 |
| 打包器可能删掉任意目录 | `-Out` 已存在时先 `Directory.Move` 挪走再无条件 `Remove-Tree` | 新增 `-Force`；不是旧光盘且非空 → 拒绝并 exit 1 |
| `Copy-Tree` 跟着 reparse point 走 | 目录联接会把盘外内容复制进光盘 | 跳过 `ReparsePoint` 并记警告 |
| `Test-Disc` manifest 键可越界 | `..\..` 之类的键会读到盘外文件 | 先 `GetFullPath` 再校验必须落在盘根下 |
| 刻录失败可能误报 BURN_OK | 用 `if ($writeError)` 判字符串真值，消息为空时判假 | 改布尔标志 `$writeFailed`，空消息补 HRESULT 说明 |
| Studio 可覆写引擎脚本 | `/api/export` 的 `dir` 只要求「在工作区内」 | 必须正好等于 `persona\<slug>`（或房间内同名结构） |
| Studio 的 `/api/iso` 可删任意文件 | 只做 `IsPathRooted`，且恒传 `-Force` | 加根目录白名单（disc 限 workspace + 房间、iso 限 workspace）+ `.iso` 后缀 |
| Studio CSRF 正门 | Origin 白名单里含 `'null'`（沙箱 iframe / `data:` 页面的 Origin） | 删掉 `'null'`，另加 `Sec-Fetch-Site` 白名单（`same-origin` / `none`） |
| 守望者 WMI 故障时 100% CPU | watcher 构造在 try 外，`catch [ManagementException] { continue }` 无 sleep | 构造移入循环、失败 10 s 重试、区分超时与非超时、加 sleep |
| 守望者吞掉首次拉起 | 去重状态在 `Start-Process` **之前**写 | 改为拉起成功后写；同时监听 EventType 2 与 3（卸载清状态） |
| 草稿里一个坏字段让 UI 半死 | `Object.assign(state, JSON.parse(raw))` 无校验，`identity: null` 让 `render()` 抛异常 | `normalizeState()` 以默认值为模板逐字段校验，坏字段回落 |

### 12.2 回归测试

`engine\_selftest
un-tests.ps1` 从 15 项扩到 **17 项**，新增：

- **T13 E07 后自愈**：先用「无凭据的主 home」跑出 E07，再手工创建 `profiles\web`（模拟 payload 复制已发生），然后换成有凭据的主 home 重跑 → 必须启动成功且 `.credentials.yaml` 已补上。
- **T14 pin 不被清空**：往 `workspace.json` 塞一条 `pinnedSessionIds`，再启动一次 → 必须保留。

并发双击也做过实测：两个实例同时启动 → 一个正常启动、另一个 `E10`，不会再起两个 dsh。

### 12.4 从光盘复制来的文件带 ReadOnly（EPERM）

光盘介质上的文件一律带 `ReadOnly` 属性，`Copy-Item -Recurse` 会把它一并复制到房间。
后果不是"读不了"，而是**写不了**：

- dsh 写设置时用「临时文件 + rename 覆盖」`profiles\web\cordis.patch.yml`，
  目标只读 → `EPERM: operation not permitted, rename ... -> cordis.patch.yml`。
  界面表现是预览版说明的「继续」按不动，红字「暂时无法确认保存确认状态，请重试。」，
  设置面板同理全部失效。
- 用户手动改房间里的 `persona\persona.yml` 会被编辑器拒绝保存。

修法：`Common.ps1` 的 `Clear-DPReadOnly` 在**每一次从盘上复制之后**清一遍
（payload profile、固化的人设目录、seed、AGENTS.md），并记日志
「清除预打包 profile 的只读属性：N 个文件」。

实现上踩过一个坑：`Get-ChildItem -Recurse` 连目录一起返回，而 `DirectoryInfo` 没有
`IsReadOnly`，在 `Set-StrictMode` 下访问会抛错并中断循环（表现为"清了 3 个就停了"）。
现在只取 `-File`，并且统一用 `Attributes -band [IO.FileAttributes]::ReadOnly` 判断。

### 12.3 第二轮修复（Studio / 打包器侧）

这三条原本记在「仍未处理」，因为都在 Studio 与打包器上，不在引擎里；现在都修完并测过：

| 编号 | 问题 | 修法 | 验证 |
| --- | --- | --- | --- |
| S1 | `New-ProfilePayload -Out` 没有根目录限制，而内部 `Remove-Tree` 用 `robocopy /MIR` 清空目标 → 指错一次就删用户目录 | 新增 `Test-UnderAllowedRoot`：`-Out` 与 `Remove-Tree` 都只允许工作区或 `%LOCALAPPDATA%\DiscPersona` 之下；不在白名单报 `PAYLOAD_FAIL PL00`；覆盖已有目录时若没有 `payload.json` / `profiles\web` 会黄字警告 | `-Out C:\Windows\Temp\dp-bad` → `PAYLOAD_FAIL PL00`，目标未被创建 |
| S2 | Studio 单线程 `HttpListener`，刻录 30–60 秒期间整个界面假死 | `/api/burn` 支持 `async: true`：立刻返回 `jobId`，后台 `Start-Process` 跑 `Burn-Iso.ps1`；新增 `GET /api/job?id=` 返回 `{done, exitCode, output}`；前端 `waitJob()` 每 700 ms 轮询，期间界面照常可用 | 对不存在的 `Z:` 发起异步刻录 → `jobId` 立返，3 秒内 `done:true, exitCode:1`，输出含 `BURN_FAIL B01` |
| S3 | 读凭据的正则只认 `DEEPSEEK_API_KEY: sk-…`，带引号的写法读不到 | 正则改 `DEEPSEEK_API_KEY:\s*["']?(sk-[A-Za-z0-9_-]+)` | `DEEPSEEK_API_KEY: "sk-quoted123abc"` → 取到 `sk-quoted123abc` |

刻录异步的两个实现坑（都已绕过，改动时别退回）：

- `Start-Process` 带 `-RedirectStandardOutput/-Error` 时 **`ExitCode` 读回空**（PowerShell 5.1）。所以每次任务生成一个一次性 `wrapper.ps1`，末尾 `Write-Output ('EXITCODE=' + $LASTEXITCODE)`，服务端用 `EXITCODE=(-?\d+)` 从输出里回填。
- wrapper 里**参数名必须裸写**（`-IsoPath`），加了引号会被当成位置字符串 → 子进程报 `PositionalParameterNotFound`。
- 子进程输出是系统代码页（中文 Windows 是 GBK），`Read-JobText` 先按 UTF-8 严格解码，失败再退回 `Encoding::Default`，否则中文日志会变乱码。

---

## 13. Linux 端口（`engine/launch.js`）

Linux 侧是同一套启动流程的 Node.js 实现，与 `launch.ps1` **并存**、共享同一份光盘格式与房间布局：

```
start.sh  →  node engine/launch.js --disc-root <disc> [--dsh-path ...] [--home-root ...] ...
```

参数一一对应（kebab-case）：`--dsh-path` / `--home-root` / `--start-timeout-sec` / `--no-browser` /
`--upgrade-persona` / `--no-wait`；环境变量仍是 `DISCPERSONA_DSH`、`DISCPERSONA_SOURCE_HOME`、
`DISCPERSONA_HOME`，另有 `DISKLIFE_NODE` 供 `start.sh` 指定 node。

### 13.1 平台差异

| 项 | Windows (`launch.ps1`) | Linux (`launch.js`) |
| --- | --- | --- |
| 平台检查 | Windows + PowerShell ≥ 5.1 → 否则 E05 | Linux + Node ≥ 18 → 否则 E05 |
| 房间兜底 | `%LOCALAPPDATA%\DiscPersona\personas` | `${XDG_DATA_HOME:-~/.local/share}/DiscPersona/personas` |
| 进程存活/启动时间 | `Get-Process` + `StartTime.Ticks` | `/proc/<pid>/stat` 第 22 字段（starttime，时钟滴答） |
| 进程树终止 | `taskkill /T /F` | `detached: true` 起进程组，`process.kill(-pid, 'SIGKILL')` |
| 启动子进程 | `cmd /d /s /c "... > log 2> err"` | `spawn(dsh, args, {detached:true, stdio:[ignore,fd,fd]})` + `unref()` |
| 打开浏览器 | `Start-Process <url>` | `xdg-open <url>`（detached，失败不阻塞） |
| 读 dsh stdout | `FileShare.ReadWrite` | 普通读取日志文件（POSIX 无共享锁问题） |
| 换行 | `.ps1` / `.cmd` 为 CRLF + BOM | `.js` / `.sh` 为 LF、无 BOM |
| 写 JSON | 手写序列化器（PS 5.1 空数组坑） | `JSON.stringify`（数组保持 `[]`） |

以下契约完全一致，Linux 侧逐条照搬：错误码 E01–E12 与退出码、必需文件、manifest 校验（含
`..` 越界拒绝）、房间解析顺序、人设「首启固化 / 房间优先 / pending 升级 / `--upgrade-persona`
备份」、凭据分块搬运、seed 与 `AGENTS.md` 幂等补齐、人设卡同步、工作区 pin（真实数组）、
`persona.patch.yml` 形状、payload 首启复制与「丢弃后冷启重试一次」、单实例锁（早写锁、
成功后改写为 dsh PID）、端口复用与 `--port 0` 重试、stdout 就绪 URL 轮询、`logs/launch-*.log`
保留 10 个、TTY 才等待按键、E10 退出码 0。

### 13.2 Linux 上不做的部分

- 不检测光盘是否为「钥匙」（与 Windows 相同）。
- 不调用任何外部命令（除 `dsh` 与 `xdg-open`），不依赖 `bash` 之外的 shell 功能；`start.sh` 是
  POSIX sh，`engine/launch.js` 只用 Node 内置模块。
- 自测：`node engine/_selftest/run-tests.js`，用 `stub-*.sh` 代替 dsh，覆盖与
  `run-tests.ps1` 相同的 17 项断言（T1、T1-patch、T1-state、T1-seed、T2–T14）。
