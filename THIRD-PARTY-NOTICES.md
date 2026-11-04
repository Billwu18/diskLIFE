# Third-party notices · 第三方组件声明

`payload/<preset>/profile-web/` are **prebuilt profile snapshots** committed to this repository so that a disc
works offline. It contains the packages below. All are MIT-licensed; the full text of each license is in
[`licenses/`](licenses/).

`payload/<preset>/profile-web/` 是随仓库提交的**预构建 profile 快照**（按插件包分组），为的是光盘离线可用。其中包含下列包，
全部为 MIT 许可，许可证原文见 [`licenses/`](licenses/)。

| Package | Version | License | License text |
| --- | --- | --- | --- |
| `@deepseek-ai/cosmokit` | 1.8.6 | MIT | [`licenses/cosmokit.LICENSE.txt`](licenses/cosmokit.LICENSE.txt) |
| `@deepseek-ai/schemastery` | 3.18.5 | MIT | [`licenses/schemastery.LICENSE.txt`](licenses/schemastery.LICENSE.txt) |
| `@standard-schema/spec` | 1.1.0 | MIT | [`licenses/standard-schema-spec.LICENSE.txt`](licenses/standard-schema-spec.LICENSE.txt) |
| `dsh-persona-dafeiyu` | 0.7.4 | MIT | [`licenses/dsh-persona-dafeiyu.LICENSE.txt`](licenses/dsh-persona-dafeiyu.LICENSE.txt) |
| `dsh-soul-md` | 0.11.0 | MIT | [`licenses/dsh-soul-md.LICENSE.txt`](licenses/dsh-soul-md.LICENSE.txt) |
| `dsh-context-compress` | 0.2.2 | MIT | 该包 `package.json` 声明 MIT，但作者未随包分发 LICENSE 文件 |
| `dsh-faster-compress` | 0.2.4 | MIT | [`licenses/dsh-faster-compress.LICENSE.txt`](licenses/dsh-faster-compress.LICENSE.txt) |
| `dsh-read-image-compress` | 0.15.0 | MIT | [`licenses/dsh-read-image-compress.LICENSE.txt`](licenses/dsh-read-image-compress.LICENSE.txt) |

Additionally, `payload/<preset>/profile-web/node_modules/.pnpm/` may contain transitive dependencies of the
packages above. They are resolved by pnpm during `tools/New-ProfilePayload.ps1`; each keeps its own
license in its package directory. The shipped set was audited to contain **MIT-only** packages — no
GPL/AGPL/SSPL code is bundled.

`payload/<preset>/profile-web/node_modules/.pnpm/` 可能还包含上述包的传递依赖，由 `tools/New-ProfilePayload.ps1`
在构建时解析；每个包在自己的目录里保留许可证。本次随仓库分发的集合已核对为**仅 MIT**，未打包
GPL/AGPL/SSPL 代码。

## Rebuilding the payload · 重建载荷

```powershell
powershell -ExecutionPolicy Bypass -File tools\New-ProfilePayload.ps1 -Preset comfort -Out payload\comfort\profile-web -Force
```

If you add plugins, **check their licenses yourself** and append them here plus in `licenses/`.
This project's MIT license does not cover third-party packages.

如果你新增了插件，请自行确认许可证，并在本文件与 `licenses/` 中补上。本项目的 MIT 不覆盖第三方包。

## Not affiliated · 无关联

DeepSeek Harness and the `@deepseek-ai/*` packages are products of their respective owners. This
repository redistributes two community plugins and two small utility packages **as installed by npm**,
with their license texts, solely so a disc can run offline. No endorsement is implied.

DeepSeek Harness 与 `@deepseek-ai/*` 包归其权利人所有。本仓库只按 npm 安装后的原样转发两个社区插件与
两个小工具包，并附许可证原文，仅为让光盘离线可运行，不表示任何背书关系。
