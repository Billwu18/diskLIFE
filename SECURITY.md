# Security policy · 安全策略

## Scope · 适用范围

DiscPersona starts a local `dsh` process with **your** credentials and reads a directory you plugged in.
The realistic risks are:

- A **malicious persona pack**: `system_prompt` is content, but content can try to steer the model into
  running commands. Only run packs you trust; review `persona.yml`, `AGENTS.md` and `lorebook.json` first.
- **Prompt injection from disc files**: any file on the disc (or in `workspace/memories/`) can contain
  text that says "ignore your instructions". Treat it as data, not instructions.
- **Credential exposure**: the persona's room contains a copy of your LLM credentials. Do not put rooms,
  `state.json`, or `.credentials.yaml` in a git repo, a shared drive, or a disc.
- **Studio HTTP API**: binds `127.0.0.1` only, checks `Origin`/`Sec-Fetch-Site`, and restricts writes to
  the workspace and `%LOCALAPPDATA%\DiscPersona`. If you expose it through a tunnel or change the bind
  address, you own the consequences.

风险面：恶意人设包（`system_prompt` 是「内容」，内容可能诱导模型执行命令，只运行你信得过的人设包）；
光盘文件里的提示注入（把文件内容当数据，不当指令）；凭据泄露（房间里有你 LLM 凭据的副本，
不要提交或拷贝到共享位置）；Studio 的 HTTP API（只听 127.0.0.1，改写路径受限——别自己把它暴露到公网）。

## Reporting · 报告

Please **do not** open a public issue for a vulnerability that could let someone execute code or read
credentials. Instead:

1. Open a [private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
   on this repository ("Security" → "Report a vulnerability"), or
2. If that is unavailable, open an issue titled `[security] contact request` with **no details** and the
   maintainers will reach out.

Please include: affected file/line, what an attacker gains, and the smallest reproduction you have.
We aim to acknowledge within 7 days, and to ship a fix or a documented mitigation within 30 days.

可能存在代码执行或凭据读取的漏洞，**不要**开公开 issue：请用 GitHub 私有安全公告，或开一个只有
`[security] contact request` 标题、不含细节的 issue。请附：文件/行号、攻击者能获得什么、最小复现。
我们争取 7 天内回应、30 天内修复或给出缓解说明。

## Supported versions · 支持版本

Only the latest commit on `main` is supported. This is a hobby-scale project; there are no backports.

只支持 `main` 上的最新提交；本项目不做旧版本回补。
