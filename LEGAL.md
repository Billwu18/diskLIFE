# Legal notice · 法律声明

> This document is a plain-language notice, not legal advice. Laws differ by country; if you plan to
> distribute discs or persona packs publicly, check your local rules first.
>
> 本文是说明性文字，不构成法律意见。各地法律不同；若你要公开分发光盘或人设包，请先确认当地规定。

---

## 1. No affiliation · 无关联声明

DiscPersona is an independent, community project. It is **not** affiliated with, endorsed by,
sponsored by, or approved by:

- DeepSeek or any entity behind DeepSeek Harness;
- any game, anime, film, or publishing company;
- any CD-R/media manufacturer or optical-drive vendor.

All product names, logos and trademarks mentioned in the documentation belong to their respective
owners and are used only for identification (nominative fair use). This project ships **no** logos,
art assets, or other proprietary material of those owners.

DiscPersona 是独立的社区项目，与 DeepSeek / DeepSeek Harness 背后的任何主体、与任何游戏、动画、影视、
出版公司、与任何光盘或光驱厂商**均无关联**，未获其背书、赞助或授权。文档中出现的产品名、标识、商标
归各自权利人所有，仅用于指称（nominal use）。本项目**不附带**上述权利人的任何 logo、美术资源或专有素材。

## 2. Character and persona content · 角色与人设内容

This repository contains **one original sample persona** (`examples/sample-persona/`, the character
"蓝色大肥鱼" / Blue Fat Fish) and an avatar drawn pixel-by-pixel in code. It deliberately contains **no** character
from any existing work.

The sample persona is *meme-flavoured, not meme-derived*: it is written in the spirit of the popular
"blue fat fish" reaction-image genre, but it is our own text and our own geometric drawing — no sticker
image, no third-party artwork, no character name from an existing work. If you replace it with the
actual meme (or any other character), that substitution and its licensing are yours.

If you create a persona based on a copyrighted character, **you** are responsible for that choice:

- Personal, private use is generally lower-risk; public distribution, sale, or commercial use is not.
- Do not ship artwork, voice lines, music, or text ripped from a game/anime.
- Fan-work tolerance policies are set by each rights holder and can change at any time; a policy that
  allows fan art does not automatically allow redistributing a character as a software product.
- If a rights holder asks for removal, the maintainers will comply for content hosted in this repo.

本仓库只包含**一个原创示例人设**（`examples/sample-persona/`，角色「蓝色大肥鱼」/ Blue Fat Fish）和由代码逐像素
绘制的头像，刻意**不含**任何既有作品的角色。

示例人设是「表情包风格、但不是表情包复制」：语感上贴近网络流行的「蓝色大胖鱼」反应图，但文字是我们写的，
图形是代码画的——没有使用任何表情包图片、第三方美术、或既有作品的角色名。如果你把它换成真正的表情包
（或别的角色），替换行为与相应授权由你负责。

如果你基于受版权保护的角色制作人设，**风险由你承担**：个人私下使用风险较低；公开分发、售卖、商用则不是。
不要附带从游戏/动画中提取的美术、语音、音乐或文本。各权利人的同人容忍政策随时可能变化，
「允许同人创作」不等于「允许把角色做成软件产品分发」。若权利人要求下架本仓库内托管的内容，维护者会配合。

## 3. Optical media, burning, and DRM · 光盘、刻录与 DRM

- The project writes ordinary ISO 9660 + Joliet images and burns them through the Windows IMAPI2 API.
  It does **not** contain, distribute, or link to any DRM-circumvention technology, and it does not
  bypass any protection: it merely invokes the official `dsh` command-line interface that you already
  installed and logged into.
- Burning discs, creating autostart entries, and distributing media may be regulated where you live
  (copyright levies, media labelling, export rules). You are responsible for compliance.
- CD-R is write-once. A failed burn, a scratched disc, or a drive that misreads it can make a persona
  permanently unrecoverable **from that disc**. Keep the ISO or the source folder.
- Cheap media and aging drives fail silently; always verify a burned disc (`Test-Disc.ps1 -Disc X:\`)
  before relying on it.

本项目只生成普通的 ISO 9660 + Joliet 镜像，并通过 Windows 官方 IMAPI2 接口刻录。它**不包含、不分发、
不链接**任何规避技术保护措施的工具，也不绕过任何保护：只调用你已安装并登录的官方 `dsh` 命令行。

刻录光盘、创建自动运行项、分发介质在你所在地区可能受法规约束（版权补偿金、介质标识、出口管制等），
合规责任在使用者。CD-R 只能写一次：刻坏、划伤、光驱读不出，都可能让这张盘上的人设**永久无法恢复**——
请保留 ISO 或源目录。劣质盘与老化光驱会静默失败，依赖之前务必回读校验。

## 4. Software provided "as is" · 软件按现状提供

The software is provided under the MIT License, **without warranty of any kind**, express or implied,
including but not limited to the warranties of merchantability, fitness for a particular purpose and
non-infringement. In no event shall the authors or copyright holders be liable for any claim, damages
or other liability, whether in an action of contract, tort or otherwise, arising from, out of or in
connection with the software or the use or other dealings in the software.

Known ways this can hurt you, stated plainly:

- **Data loss.** A persona's room contains its memory. Deleting it, or reusing a `pad.bin` across two
  discs, can destroy or mix memories irreversibly. There is no cloud backup.
- **Cost.** Every conversation calls your own LLM provider and is billed to your account.
- **Third-party breakage.** DSH is in preview (0.2.x); CLI flags, profile layout and plugin APIs can
  change and break the launcher. Pinning versions is your responsibility.
- **Security.** The launcher runs `dsh` as your user, with your credentials, in a directory on your
  disk. Persona packs are executable *content* in the sense that a malicious `system_prompt` can try to
  steer the model; only run packs you trust.

本软件按 MIT 许可证「按现状」提供，**不附带任何明示或默示担保**，包括但不限于适销性、特定用途适用性
与不侵权担保。作者与版权持有人不对任何索赔、损害或其他责任负责。

说人话，以下是它可能怎么伤到你：**数据丢失**（房间就是记忆，删了或两张盘复用同一个 `pad.bin` 会不可逆地
丢失/混淆记忆，没有云备份）；**费用**（每次对话都走你自己的 LLM 账号计费）；**第三方变动**
（DSH 仍是 0.2.x 预览版，CLI 参数、profile 结构、插件 API 都可能变，请自行锁版本）；
**安全**（启动器以你的身份、你的凭据运行；人设包是「内容」，恶意 system prompt 可能试图操控模型——
只运行你信任的人设包）。

## 5. Privacy · 隐私

- **No telemetry.** The project contains no analytics, no phone-home, no auto-update.
- **Local credentials.** On first run the launcher copies LLM credentials from your existing DSH home
  into the persona's room, so the isolated instance can talk to the model. Nothing is uploaded by this
  project; the file stays on your disk. Treat the room as sensitive as your main home.
- **Conversations leave your machine** to whichever model provider you configured, under that
  provider's terms. This project cannot change that.
- **Never commit secrets.** `.gitignore` excludes credentials, sessions, rooms, ISOs and builds. If you
  fork this repo, do not commit `%LOCALAPPDATA%`/room contents, `.credentials.yaml`, or persona packs
  that contain personal data.
- **Discs are portable.** Anything you put in a persona pack is readable by anyone who picks up the
  disc. Do not put addresses, phone numbers, private notes, or other people's data on a disc.

本项目不含任何遥测、回传或自动更新。首启时启动器会把你本机既有 DSH 的 LLM 凭据**复制**一份进人格房间
（仅本机、不上传）；请把那间房当成和主 home 一样敏感。对话内容会按你所配置的模型服务商条款离开本机，
本项目无法改变这一点。**不要把凭据提交进仓库**：`.gitignore` 已排除凭据、会话、房间、ISO 与构建产物。
**光盘是便携介质**：放进人设包的任何内容，捡到盘的人都能读——不要写地址、电话、私人笔记或他人信息。

## 6. AI-generated output · AI 生成内容

Personas are role-play. Model output can be wrong, biased, or fabricated, even when it sounds certain.
Nothing a persona says is professional advice (medical, legal, financial, safety). Do not rely on it for
decisions with real consequences, and do not let a persona's "in-character" framing override factual or
safety requirements in your work.

人设是角色扮演。模型输出可能错误、有偏或凭空编造，即使听起来很确定。人格说的任何话都不构成专业建议
（医疗、法律、金融、安全）。不要用它做有真实后果的决定，也不要让人设的「入戏」压过事实与安全要求。

## 7. Third-party components · 第三方组件

`payload/profile-web/` redistributes npm packages, all MIT-licensed, with their license texts in
[`licenses/`](licenses/) and a summary in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
No GPL/AGPL/SSPL code is bundled. If you rebuild the payload with other plugins, check their licenses
yourself: this project's MIT license does not cover them.

`payload/profile-web/` 内是随盘分发的 npm 包，均为 MIT，许可证原文在 [`licenses/`](licenses/)，
汇总见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。未打包 GPL/AGPL/SSPL 代码。
如果你用其他插件重建载荷，请自行确认其许可证——本项目的 MIT 不覆盖它们。

## 8. Contributions · 贡献

By submitting a pull request, issue text, or any other contribution, you agree to license it under the
MIT License and confirm you have the right to do so. Do not contribute code or content you do not own,
or that is copied from a proprietary product.

提交 PR、issue 文本或其他贡献，即表示你同意以 MIT 许可证授权，并确认你有权这样做。
不要贡献你不拥有的、或从专有产品复制的代码与内容。

## 9. Reporting · 举报与下架

- Copyright/trademark concerns: open an issue titled `[legal] ...`, or contact the maintainers privately
  if the matter is sensitive.
- Security vulnerabilities: see [SECURITY.md](SECURITY.md).

版权/商标问题：开一个标题为 `[legal] ...` 的 issue；敏感事项请私下联系维护者。
安全漏洞：见 [SECURITY.md](SECURITY.md)。
