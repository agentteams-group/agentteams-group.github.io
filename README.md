# AgentTeams 官网

`https://agentteams.cloud` 的静态官网源码，部署仓库为
[`agentteams-group/agentteams-group.github.io`](https://github.com/agentteams-group/agentteams-group.github.io)。

## 本地开发

使用 Node.js 24（版本见 `.nvmrc`）和 npm：

```bash
nvm use
npm ci
npm run dev
```

开发服务器默认地址：`http://localhost:4321`。
未安装 nvm 时，可以使用其他 Node.js 版本管理工具安装 Node.js 24。

```bash
npm run check        # Astro / TypeScript 检查
npm test            # 构建验证和发布行为测试，无云端调用
npm run build       # 静态构建 + 页面、资源、链接与锚点检查
npm run deploy:plan # 输出上传顺序及缓存策略，不需要凭证，不执行上传
npm run preview     # 预览 dist，默认 http://localhost:4321
```

## 页面与目录

| 路径 | 内容 |
| --- | --- |
| `/` | 产品首页、Dashboard 协作 GIF、一行安装命令、协作流程与基础设施介绍 |
| `/quickstart/` | 本地安装、Dashboard 入口和首次协作的简要指南 |
| `/docs/` | Dashboard、部署、架构和排障文档入口 |
| `/docs/architecture/` | 系统角色与协作基础设施概览 |
| `/community/` | 问题反馈、代码贡献、文档及版本入口 |
| `/404.html` | 不存在页面的错误页 |
| `/agentteams-install.sh` | 随官网发布的稳定安装脚本 |
| `/agentteams-dashboard.sh` | 为已有 AgentTeams 补装 Dashboard 的稳定脚本 |

```text
src/
  components/           # 共享组件
  layouts/              # 页面框架与 SEO 元信息
  lib/site.ts           # 主仓地址、站点信息、安装命令与导航
  pages/                # Astro 文件路由
  styles/site.css       # 响应式样式
public/                 # 原样复制到 dist 的公开资源
scripts/                # 构建验证、OSS 上传、线上验证
tests/                  # 发布关键行为测试
.github/workflows/      # PR 检查和 main 自动发布
docs/deployment.md      # GitHub / OSS / 网关 / 域名配置与回滚
docs/installer.md       # 稳定安装脚本的来源、升级与验收流程
installer-release.json # 当前安装版本、来源 commit 和文件校验值
dashboard-installer-release.json # Dashboard 独立版本与来源、校验值
```

当前首版提供中文页面，不展示尚未实现的语言入口。首页使用本地 Dashboard 的真实协作演示，
将原生 2 倍像素 PNG（1872 × 1302）合成为 `public/images/dashboard-collaboration.gif`，共 9 个关键画面、44 秒循环，略去执行等待时间。
演示围绕 Orbit Notes 校园上线方案，展示提出目标、Manager 分工、Worker 初稿、Human 补充约束、验收修订，
以及 Worker 生成的 HTML 页面预览。
动图自动循环播放，支持停止、播放和放大观看；系统开启“减少动态效果”或禁用 JavaScript 时，
显示 `public/images/dashboard-collaboration.png` 静态封面。更新时使用公开示例内容，
避免出现密钥、私人对话与内部项目；不要将有损图片转为 PNG 或放大旧图代替重新截图。
页头品牌区与首页首屏共用 1380px 最大宽度，保持左边线对齐。品牌 Logo 保存为 `public/logo.svg`；
页头与页脚复用该文件，`public/favicon.svg` 使用同一图形作为浏览器图标。
首页参考 [Teamily](https://teamily.ai/) 的产品展示方式，以真实界面、协作成果和清晰的开始入口组织内容。
首页、文档入口与社区页的标题区使用深青至绿色渐变背景与品牌绿，正文采用浅色阅读区域。
左上角品牌旁提供商业版 AgentCore 入口，跳转到阿里云产品页。
主导航按首页、产品、Dashboard、文档、社区排列；产品入口定位到首页的产品介绍区。
共享色彩变量在 `src/styles/site.css` 中维护。

## 内容维护

- 首页、简要指南和导航在本仓维护；更新产品行为时，核对主项目对应文档。
- 完整产品文档继续在 [AgentTeams 主仓](https://github.com/agentscope-ai/AgentTeams/tree/main/docs)
  维护，当前官网直接链接到该来源，不在两个仓库复制整套文档。
- 首页和快速开始统一使用 `curl -fsSL https://agentteams.cloud/agentteams-install.sh | bash`。
  完整脚本和许可证在 `public/` 中维护，
  默认版本固定到已选定的正式 Release，普通构建不会追随上游 `main`。升级使用
  `npm run installer:update -- vX.Y.Z`，详见 [稳定安装脚本维护](docs/installer.md)。
- `Check installer releases` 每小时检查 AT 与 Dashboard 的正式 Release，更新和检查成功后自动创建升级 PR；验收合并后才发布到 OSS，也支持在 Actions 中手动运行。
- Dashboard 独立启动入口使用 `https://agentteams.cloud/agentteams-dashboard.sh`，首页 Dashboard 区域和
  快速开始文档提供命令；使用 `npm run installer:update:dashboard -- vX.Y.Z` 单独升级其稳定版本。
- Dashboard 内容以 [开源 Dashboard 仓库](https://github.com/agentteams-group/agentteams-dashboard) 为来源，
  安装集成行为以 AgentTeams 主仓的本地部署指南为准；介绍、快速开始和架构图应同步维护。
- 站内链接采用目录形式，例如 `/docs/architecture/`。新增页面时应更新文档导航；核心页面应加入
  `scripts/validate-build.mjs` 的必需产物清单。
- `public/` 中只能放可公开资源。不要放入凭证、私有配置、源码仓库或构建缓存。
- 架构图源文件为 `public/architecture.svg`，由 `ArchitectureDiagram.astro` 在首页和架构文档页复用。
  图中文字、图标与连线均为矢量元素，可无损放大；图中表达逻辑关系，省略部署与代理细节。
  更新组件关系时同步修改图中文字及无障碍描述；窄屏支持在图内横向滚动和查看原图。
- `dist/` 和依赖目录不提交 Git。官网域名在 `astro.config.mjs`、`public/robots.txt`
  和 `scripts/validate-build.mjs` 中保持一致。

## 自动发布

1. PR 运行类型检查、测试、构建、产物验证及发布预演，并保留构建产物。
2. `main` push 或在 `main` 手动运行工作流，执行相同验证。
3. 仓库变量 `OSS_DEPLOY_ENABLED=true` 时，部署通过 `website-production` Environment 执行。
4. 部署下载本次构建的产物，通过阿里云官方 OSS Node.js SDK 上传。先资源、后 HTML、首页最后。
5. 配置 `SITE_URL` 后验证线上页面、CSS/JS、404、Content-Type，并比对本次构建内容。

没有配置部署开关时，CI 正常验证并记录跳过部署的原因。首次启用及所需 Variables、Secrets
见 [部署说明](docs/deployment.md)。本地生成这些文件不会创建云资源、修改 DNS 或开启 GitHub 部署。
