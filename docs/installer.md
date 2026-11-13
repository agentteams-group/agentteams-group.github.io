# 官网稳定安装脚本

官网入口为 `https://agentteams.cloud/install.sh`，由本仓的
`public/install.sh` 随网站构建和 OSS 发布。它是完整脚本，运行时不再从 GitHub `main` 下载安装器。
域名、网关和 OSS 首次部署完成后，此地址才对外可用。

```bash
curl -fsSL https://agentteams.cloud/install.sh | bash
```

在交互式终端中执行。官网脚本先完整解析，再将安装向导的输入连接到 `/dev/tty`，
因此管道中的脚本内容不会被当成向导答案；无需在当前目录保存脚本。可直接在浏览器中打开脚本地址审阅。

也可以先下载审阅，再通过 `bash agentteams-install.sh` 执行。文件执行会保留标准输入，
兼容重定向答案。无终端的自动化执行需在 `bash` 一侧设置 `AGENTTEAMS_NON_INTERACTIVE=1`，
并提供上游要求的配置变量；缺少终端的交互式管道执行会在安装前退出。

## Dashboard 独立启动

Dashboard 入口为 `https://agentteams.cloud/agentteams-dashboard.sh`，完整文件为
`public/agentteams-dashboard.sh`，版本、来源 commit 和校验值单独保存在 `dashboard-installer-release.json`。

```bash
curl -fsSL https://agentteams.cloud/agentteams-dashboard.sh | bash
```

此脚本用于在同一台主机的已有 AgentTeams 环境中补装 Dashboard：Docker / Podman 必须可用，
并且 `agentteams-net` 网络已存在。若主安装流程已启用 Dashboard，直接访问其地址，无需重复安装。
按向导确认 Controller、Matrix 和 Higress 地址，默认访问 `http://127.0.0.1:13000`。

官网副本校正该 Release 脚本的默认镜像版本，默认仅绑定本机；显式设置 `AGENTTEAMS_LOCAL_ONLY=0`
仍可选择局域网访问。镜像拉取失败会停止，不从下载目录的父目录寻找 Dockerfile 并构建。
`update` 子命令重新拉取已保存配置中的镜像，失败时保留当前容器；它不自动切换到官网新选择的版本。

单独更新官网 Dashboard 脚本使用 `npm run installer:update:dashboard -- vX.Y.Z`，
遵循下面相同的验收与发布流程。许可证为 `public/agentteams-dashboard.LICENSE`。

## 当前版本与修改范围

- 发布版本、不可变来源 commit、上游 SHA-256 和官网文件 SHA-256 记录在根目录 `installer-release.json`。
- AgentTeams 与 Dashboard 的当前版本和来源 commit 分别以 `installer-release.json`、`dashboard-installer-release.json` 为准，页面读取同一份元数据。
- 保留上游安装逻辑，官网补丁支持交互式管道启动，并将默认镜像版本固定为该稳定版本；向导返回上一步时仍恢复这个默认值。
- 默认路径沿用上游完整镜像集合预检，缺少稳定镜像时停止。指定版本的 embedded 镜像拉取失败也停止，禁止隐式回退到 `latest`。
- 显式设置 `AGENTTEAMS_VERSION` 或镜像覆盖变量仍遵从上游行为；这属于用户自选配置，不属于官网默认稳定组合。
- Dashboard 保持独立版本；从 Core 1.2.7 起，六种 Worker 默认使用 `agentteams-harness-xxx` 镜像并跟随 Core 版本，Manager 复用 OpenClaw / QwenPaw 镜像。容器镜像仍由上游镜像仓库提供；官网不托管镜像，不保证镜像仓库的网络可用性。
- 上游许可证保存在 `public/agentteams-install.LICENSE`，脚本头部保留来源与修改说明。

## 升级稳定版本

维护者需要 Node.js 24、Bash、curl 和已登录的 GitHub CLI（`gh`）。升级是显式维护操作，不在每次网站构建中自动运行。

1. 等待上游正式 Release 和对应平台镜像发布完成。
2. 在官网分支执行 `npm run installer:update -- vX.Y.Z`，使用实际 Release tag。`main`、`latest`、草稿和预发布均不接受。
3. Core 更新器核实 Release 与 commit 后，更新本仓安装器的稳定版本、别名及校验和，不下载 Core 脚本。Dashboard 更新器仍按其发布 commit 下载独立脚本与许可证。
4. 审阅本仓安装器、镜像默认值及 `installer-release.json` 的差异；安装逻辑直接在本仓修改并补充行为测试。
5. 在干净的 Linux/macOS 容器环境中验收真实安装和需要支持的升级场景，再运行 `npm run check`、`npm test`、`npm run build`、`npm run deploy:plan`。
6. 合并官网 `main`，由现有 `Website` Actions 发布。页面上的稳定版本提示自动读取同一份元数据。

CI 的测试使用模拟容器命令，不会安装 Docker、启动 Agent 或调用模型 API；不能替代新版本的真实安装验收。
网站普通构建只使用已提交文件，不请求最新 Release，也不会自动修改已选中的稳定版本。

## 发布、缓存与回滚

- 构建和上传前检查安装脚本及许可证必须存在，SHA-256 必须匹配元数据，安装脚本必须通过 `bash -n`。
- 两个脚本均以 `text/plain; charset=utf-8` 和 `Cache-Control: no-cache` 上传；网关须保留这些响应头，避免对脚本强制套用长缓存。
- 脚本与其他静态资源在 HTML 之前上传。配置 `SITE_URL` 后，线上检查会验证脚本的状态码、Content-Type、缓存头及逐字节内容，防止网关将脚本路径回退到首页。
- 回滚官网成功构建的完整 artifact，会同时恢复安装脚本及页面。见 [部署文档](deployment.md)。
- 若只回退安装版本，需要一并恢复该脚本、许可证和对应的 `installer-release.json` 或 `dashboard-installer-release.json`，重新检查并发布。

稳定入口是可更新地址。它解决官网发布与上游开发分支不同步的问题；版本镜像采用上游 tag，并非 digest 固定。

Windows PowerShell 安装器发布在 `/install.ps1`，与 Bash 安装器同步自同一个 Core 发布提交，默认固定稳定版本；校验和记录在 `installer-release.json` 的 `powershell` 字段，发布时校验内容并以不缓存的纯文本提供。

`/install.sh`、`/install.ps1` 是推荐入口；旧 `/agentteams-install.sh`、`/agentteams-install.ps1` 保留，内容与短地址逐字节一致，由同一同步流程生成并校验。

## 独立维护

Core 安装器的唯一源文件为 `public/install.sh` 和 `public/install.ps1`，不再从 AT 仓库导入实现。修改源文件后执行 `npm run installer:update -- v1.2.7`，该命令只查询已发布版本的元数据、刷新别名与校验和；功能变更必须通过本仓测试和安装验收。切换版本时还需审阅六种 Harness 与 Dashboard 默认版本。Dashboard 独立安装器仍按其仓库发布流程导入。
