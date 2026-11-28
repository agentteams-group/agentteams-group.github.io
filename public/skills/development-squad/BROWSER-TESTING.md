# 研发小队浏览器测试环境：一次准备，后续复用

此文档规范平台运维/团队管理员的安装步骤，不表示 AgentTeams 已自动部署浏览器服务。研发小队技能 1.2.0 适用于所有 Harness，安装细节不进入各 Harness 的业务判断。

## 选择与职责

优先复用已登记并授权的浏览器 MCP；其次使用平台明确提供的本地浏览器测试环境。无需浏览器的任务不安装。Developer 自测与 Tester 独立验证使用各自隔离的会话，并记录同一远端提交 SHA。共享浏览器镜像与服务，不共享登录态和测试结论。

Worker 默认镜像不因此增加 Chromium。平台管理员安装服务、登记网关并分配工具；Leader 协调环境阻塞后的原任务续办。Worker 先探测已有能力，缺少时报告具体错误，不在每个任务中重复安装、下载或依赖宿主机浏览器。

## 首次部署示例：独立 Playwright MCP

以下命令改编自 [Playwright MCP 官方 Docker / HTTP 部署说明](https://github.com/microsoft/playwright-mcp#docker)。Docker 实现提供 headless Chromium。上线前选择在目标 CPU 架构验证过的镜像并记录 digest，不把浮动 latest 当作可复现安装版本。

```sh
# 明确填写已经验证的镜像 digest、当前环境网络和本队服务名。
export BROWSER_MCP_IMAGE='mcr.microsoft.com/playwright/mcp@sha256:<verified-digest>'
export AGENTTEAMS_NETWORK='<existing-agentteams-network>'
export BROWSER_MCP_CONTAINER='<team-browser-service>'

docker pull "$BROWSER_MCP_IMAGE"
docker run -d --init --restart unless-stopped \
  --name "$BROWSER_MCP_CONTAINER" \
  --network "$AGENTTEAMS_NETWORK" \
  --entrypoint node "$BROWSER_MCP_IMAGE" \
  /app/cli.js --headless --browser chromium --no-sandbox \
  --isolated --port 8931 --host 0.0.0.0
```

这是独立服务示例，不修改现有安装器或 Worker 镜像。镜像构建好后可提前拉取到目标节点；后续复用相同 digest，不随每次 Issue 重新安装。示例不向宿主机发布端口，由网关通过同一网络访问 `http://<team-browser-service>:8931/mcp`；不同部署网络需要填写实际可达地址。隔离 profile 是测试状态隔离，不替代平台的访问控制。

## 网关登记与分配

1. 在 AgentTeams 的 MCP 资产中登记上述服务，填写实际地址、名称和必要的网关认证配置。
2. 按现有 MCP 授权流程授权本队需要的 Worker，再在 Worker MCP 列表关联该服务。仅填写地址或更新 skill 不等于已经授权。
3. 配置所需审批策略：按团队选择请求审批或自动通过。后台凭证保存在网关，不进入聊天或技能正文。
4. 让 Developer 和 Tester 各自通过真实 Worker 调用工具列表并完成浏览器烟测，确认各自可用。记录镜像 digest、浏览器/服务版本、网关资产和验证时间。

## 测试文件和网络

远端服务的 `localhost` 和 `file://` 属于浏览器服务容器，不是 Worker。提供服务可达的预览地址，或由平台只读挂载指定测试产物；不要声称服务能直接读取 Worker 本地路径。确保读取的是声明的 PR head/产物版本。要求离线 HTML 时，必须另行验证同一文件的离线行为，不能用 HTTP 页面替代。不要把整个宿主机目录或宿主机登录 profile 挂入服务。

预览服务必须在浏览器测试期间保持运行。使用运行时提供的持久前台进程/会话能力保留服务并记录进程标识；不要假定 `nohup` 或 `&` 启动的子进程在命令返回后仍存活。浏览器连接被拒绝时，先检查服务在命令返回后是否仍监听，再排查可达地址和网络；不要仅凭一次拒绝就判断容器网络隔离。测试后关闭自己启动的服务。


## 安装完成标准与复用

- 工具列表可用，并真实执行打开页面、点击、读取结果、刷新；需要时验证离线和目标视口。
- Developer 与 Tester 使用独立会话及同一声明提交，证据可追溯；测试结束关闭会话。
- 重启浏览器服务后能够重新连接并重做烟测。报告真实失败原因，而不是只记录容器 Running 或接口 200。
- 所有安装/探测操作设置有限超时；失败保留日志，先修环境，不重复启动并行下载。原 Task 按正式阻塞/续办协议继续，不新建 Issue 或主 Task 绕过。

若平台选择本地 Playwright，安装应由平台在初始化时完成一次，固定包版本、浏览器 revision、可写缓存目录和实际可执行路径，并通过同样烟测。任务只复用环境；不得把某台机器的下载缓存视为产品已提供该能力。
