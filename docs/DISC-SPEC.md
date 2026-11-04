# DiscPersona 光盘格式规范 v1

本文件是 `engine/` 与 `tools/` 之间的契约。改格式先改这里，两边再跟。

---

## 1. 目录树

```
<disc>\
  autorun.inf                 光盘入口（UTF-16LE + BOM，CRLF）
  start.cmd                   ASCII，CRLF，只做「找 PowerShell → 转交 engine\launch.ps1」
  engine\                     launch.ps1 + lib（由打包器从工作区复制）
  persona\                    Persona Pack
  pad.bin                     512 字节盘片身份文件
  .discpersona\manifest.json  完整性清单
  .discpersona\payload\       可选  预装插件载荷（profile-web\ + payload.json）
  README.txt                  给拾到这张盘的人看
```

`persona\` 内：

```
persona\
  persona.yml        必需   运行时唯一真源
  meta.json          必需   展示信息（name/version 用于首页文案）；打包器会写入 discID
  AGENTS.md          可选   家规（装进人格 home 作全局指令）
  card.json          可选   Character Card V2 兼容副本
  lorebook.json      可选   世界书；原生模式拼进 system prompt 附录
  avatar.png/.ico    可选   图标；ico 优先，缺失回退 png，都没有则无图标
  seed\              可选   初始记忆，首次启动复制进 workspace\memories\
```

### 1.1 插件载荷（`.discpersona\payload\`）

```
payload\
  payload.json          元信息（打包时可读）
  profile-web\          一份可直接用的 profiles\web
    package.json        dsh.profile.bundles 必须含插件包名
    cordis.yml
    node_modules\       硬链出来的依赖（打包时已剥掉 .cache / .pnpm-store）
```

`payload.json`：

```json
{ "format": 1, "kind": "profile-web", "builtAt": "2026-11-04T...Z",
  "dshVersion": "0.2.1-rc.5",
  "plugins": [ { "name": "dsh-soul-md", "range": "^0.11.0", "version": "0.11.0" } ],
  "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app", "dsh-soul-md"],
  "fileCount": 69, "bytes": 501234 }
```

规则：

- 整个 `profile-web\` 会被**原样复制**到 `home\profiles\web\`；引擎不再跑 `dsh plugin add`（离线）。
- `payload.json` 缺失也能启动，只是 `state.json.payloadPlugins` 为空（日志会提示）。
- 引擎会同时找 **`.discpersona\payload\profile-web\`** 和旧的 **`.discpersona\payload\` 平铺** 两种形态。
- 起不来时引擎删掉 `profiles\web`、冷启一份 vanilla profile 重试 —— **载荷是可选的，人设不是**。
- 清单里的 SHA-256 覆盖载荷目录，被改动会触发 E03（与其它文件同一规则）。

`payload.json` 里还有 `preset` 字段，标明这组载荷叫什么（`comfort` / `token` / `full`）；打包时由
`tools\New-Disc.ps1 -PayloadPreset <preset>` 选中，并把预设名与插件清单写进 `persona\meta.json` 的 `payload` 对象：

```json
"payload": { "preset": "token", "plugins": ["dsh-context-compress", "dsh-faster-compress", "dsh-read-image-compress"] }
```

生成：`powershell -File tools\New-ProfilePayload.ps1 -Preset <preset> -Out payload\<preset>\profile-web -Force`。

## 2. pad.bin

| 字段 | 偏移 | 长度 | 说明 |
| --- | --- | --- | --- |
| magic | 0 | 18 | ASCII `DISCPERSONA-PAD-V1` |
| 保留 | 18 | 46 | 空格填充 |
| 生成时间 | 64 | 32 | ASCII `yyyy-MM-ddTHH:mm:ssZ`，其余填空格 |
| 随机 | 96 | 416 | 加密随机数，保证每张盘唯一 |

- 总长固定 **512 字节**。
- 未用区域填 `0x20`（空格），便于人肉 `type pad.bin` 检查。

## 3. discID

```
discID = lower( hex( sha256( pad.bin 的 512 字节 ))[0..16] )
```

- 16 位小写十六进制。
- **唯一来源是 pad.bin**。`meta.json` 里的 discID 只是副本，与 pad.bin 不一致时以 pad.bin 为准。
- 重打包同一张盘用 `-ReusePad` 复用旧 pad.bin，discID 才不变。

## 4. manifest.json

```json
{
  "format": 1,
  "discID": "4fbd5c230b2854f6",
  "name": "天童爱丽丝",
  "version": "1.0.0",
  "builtAt": "2026-11-03T16:37:03Z",
  "engine": "1.0.0",
  "files": {
    "autorun.inf": "<sha256 hex, 小写>",
    "start.cmd": "<sha256 hex>",
    "pad.bin": "<sha256 hex>",
    "persona/persona.yml": "<sha256 hex>"
  }
}
```

- `files` 的键是**相对光盘根的路径，正斜杠**。
- 值是小写 hex 的 SHA-256（64 字符）。
- 引擎启动时校验 `files` 中的每一项；**不一致 → E03 并中止**（提示「盘被改动过」）。
- manifest 自身不参与校验（它没有自引用）。

## 5. 运行时行为的契约

1. discID 由 pad.bin 算出 → home = `<房间根>\personas\<discID>`；房间根默认跟着 dsh 安装位置（`<安装根>\DiscPersona`），可用 `-HomeRoot` / `DISCPERSONA_HOME` 覆盖，退路是 `%LOCALAPPDATA%\DiscPersona`。
2. 首启（`home\profiles\web` 不存在）：
   - 建 `home\`、`workspace\`、`logs\`；
   - `home` 作为 DSH_HOME 直接启动 shipped profile `web`（DSH 会自己落地 profile，**不需要也不允许** `--from-default-profile`）；
   - 凭据：从主 home 的 `.credentials.yaml` **块级复制** LLM 相关记录，不解析、不打印密钥；
   - 复制 `persona\seed\*` → `workspace\memories\`，复制 `AGENTS.md` → `home\AGENTS.md`。
3. 每次启动：读 `persona.yml` → 生成 patch（见 §6）→ `dsh --profile web --patch <patch> --port <port>`。
4. 二次启动（`state.json` 标记运行中且 PID 存活）→ E10，把已有窗口拉到前台，不新开实例。

## 6. persona.yml → DSH patch

最小形状（`--patch` 是**整段替换**该 id 的 config，不是深合并）：

```yaml
- id: system-prompt
  config:
    personaPrefix: |
      <system_prompt 原文，逐行缩进两格>
```

- `persona.yml` 的 `system_prompt` 块标量原样取出，**不要**改写内容、不要重排缩进以外的东西。
- 若 `lorebook.json` 存在，追加到 `personaPrefix` 末尾：

  ```
  ## 世界书（设定，不是台词）
  ### <entry.comment 或 keys 拼起来>
  <entry.content>
  ```
  **全部条目都拼**：`--patch` 通道没有关键词检索，只拼 `constant` 会让大部分世界书
  悄悄消失。排序是 `constant: true` 优先，其次按 `insertion_order`；累计上限 **6000 字**，
  超出的条目在日志里报「略过 N 条」，不会静默丢弃。
  （`dsh-soul-md` / `dsh-persona-dafeiyu` 若自带检索，属于插件侧能力，与此处无关。）
- 脚本必须 **UTF-8 无 BOM** 写出 patch；DSH 按 UTF-8 读取。
- patch 放在 `home\state\patch-<timestamp>.yml`，便于事后排查。

### 6.1 磁盘上还会被改写的两处（不属于光盘格式，但属于契约）

| 文件（在人格 home 里） | 引擎每次启动写什么 | 为什么 |
| --- | --- | --- |
| `storages\workspace.json` | 只留「房间\workspace」一间、设为默认，title = `<人设名>的房间` | dsh 默认工作区固定落在「文档」下，不改会与主实例串台 |
| `storages\dsh-persona-dafeiyu\personas.json` | `current=discpersona`、`disabled=[dafeiyu, acha]`、卡正文 = 盘上 `system_prompt` | 插件出厂会注入内置人设（大肥鱼），会和盘上人设打架 |

两者都是**尽力而为**：写不进去只记警告，不影响启动。

## 7. 错误码

错误码表、命令行开关、日志格式见 [`docs/engine.md`](engine.md)。E01–E10 由引擎实现。

## 8. 版本与兼容

- `format` 目前只有 `1`。引擎读到未知 `format` → E02（「这张盘是更新的版本做的」）。
- `persona.yml` 的 `runtime:` 字段本期只认 `native`；`agent-rp` 保留，遇到时按 `native` 运行并在日志里警告一次。
