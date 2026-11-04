# tools/ —— 造盘流水线

五个脚本，只依赖 Windows PowerShell 5.1 自带命令（不装 Node、不装 npm 包）。

```
New-ProfilePayload.ps1  装插件 → 预打包 profile（可选，一次性）
        ↓
New-Disc.ps1            人设包 + 引擎 + 载荷 → 光盘目录树
        ↓
Test-Disc.ps1           静态校验（36 项）
        ↓
New-Iso.ps1             目录树 → ISO（ISO9660 + Joliet）
        ↓
Burn-Iso.ps1            ISO → 空白 CD-R
```

## 打包：`New-Disc.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-Disc.ps1 `
  -Persona persona\aris `
  -Out D:\build\aris-disc
```

- `-Persona`：Persona Pack 目录（含 meta.json / persona.yml / AGENTS.md / seed\...）
- `-Out`：光盘目录树输出位置；已存在会被整体替换（先打 `<Out>.tmp`，成功再原子换掉旧目录）
- `-ReusePad`：复用 `<Out>\pad.bin`，让重新打包出来的 discID 保持不变

产物就是一张**数据光盘**的目录树，直接按「数据光盘」方式烧进 CD-R 即可：

```
<Out>\
  autorun.inf            label / action / icon（有 avatar.ico 用 ico，否则回退 avatar.png）
  start.cmd              工作区 start.cmd 的原样副本
  README.txt             给人看的说明（含 home 位置、错误码、别当启动盘烧）
  pad.bin                512 字节；discID = 它的 SHA-256 前 16 位小写
  engine\...             工作区 engine\ 的副本
  persona\...            Persona Pack 的副本（meta.json 的 discID 会同步成这张盘的）
  .discpersona\manifest.json   文件哈希清单（含 pad.bin 自身，文件按路径排序）
  .discpersona\payload\        预装插件载荷（若 build\payload 存在）
```

校验不通过（meta 缺 name/version、yml 缺 `system_prompt:`）会列中文原因、退出码 1，
且不产出半成品目录。

## 静态校验：`Test-Disc.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\Test-Disc.ps1 -Disc D:\build\aris-disc
```

不启动 DSH、不联网，只读盘上的文件：必需文件齐全、manifest 形状与缩进、
每个哈希与磁盘一致、没有清单外的多余文件、pad.bin 恰好 512 字节且魔数正确、
start.cmd 是 CRLF 无 BOM、autorun.inf 有 `open=start.cmd` 且 icon 指向真实文件。
逐项 ✓/✗，末尾 `PASS`（退出码 0）或 `FAIL`（退出码 1）。

## 自测

`_selftest\fake-persona\` 是最小假人设包；`_selftest\out-disc\` 是它的产物；
`_selftest\out-disc-broken\` 是把 `persona/persona.yml` 追加一行后的副本，用来确认校验会 FAIL。

## 插件载荷：`New-ProfilePayload.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-ProfilePayload.ps1 -Force
```

- `-Plugins`：要装的包，默认 `dsh-soul-md,dsh-persona-dafeiyu`
- `-Out`：输出目录，默认 `build\payload\profile-web`
- `-SkipVerify`：跳过「真启动一次」的验证（默认会验，慢十几秒但值得）

流程：建临时 home（`build\_payload-home`）→ `dsh plugin --profile web add ...` → 复制 `profiles\web` → 删
`.cache` / `.pnpm-store` → 写 `payload.json` → 真启动一次确认没报错。产物约 0.5 MB / 69 文件。

失败了先看输出里的 `PAYLOAD_FAIL` 行：通常是插件 peerDependency 与当前 dsh 版本不匹配。

## 生成 ISO：`New-Iso.ps1`

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-Iso.ps1 -Source examples\sample-disc -Out build\aris.iso
```

- `-Source`：光盘目录树（`New-Disc.ps1` 的产物）
- `-VolumeLabel`：卷标，默认取 `meta.json.nameJp`，非 ASCII 时退回 `DISCPERSONA`
- `-Force`：覆盖已存在的 ISO

走 IMAPI2（`MsftFileSystemImage`），`FileSystemsToCreate=3` 即 **ISO9660 + Joliet**——中文长文件名靠 Joliet 才不被截断。
不需要 oscdimg / mkisofs / xorriso。

## 刻录：`Burn-Iso.ps1`

```powershell
powershell -File tools\Burn-Iso.ps1 -ListDrives                 # 看有哪些光驱、盘空不空
powershell -File tools\Burn-Iso.ps1 -IsoPath build\aris.iso -DriveLetter F
```

- `-TestOnly`：只验链路，不真写（对已有内容的盘也能跑）
- `-Eject`：写完弹出托盘

结局行固定为 `BURN_OK <盘> <字节> bytes <秒>s` 或 `BURN_FAIL <Bxx> <中文原因>`：

| 码 | 含义 |
| --- | --- |
| B01 | 找不到光驱（`-DriveLetter` 写了不存在的盘符） |
| B02 | 驱动器里没有介质 |
| B03 | 介质不可写（DVD-RAM 以外的只读盘、或不是 CD-R/RW） |
| B04 | 光盘上已经有内容（**保护**：不覆盖已刻的盘） |
| B05 | ISO 文件不存在 |
| B07 | 写入失败（COM 层报错，通常是驱动器或介质问题） |
| B08 | 写完了但盘还是空白（极少见，多半是驱动器不认） |

刻录会把盘**终结**（`ForceMediaToBeClosed`），之后不能再追加——一张盘一个人。
