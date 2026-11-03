# 官网部署

## 发布与访问链路

```text
main → GitHub Actions 验证/构建 → dist artifact → OSS Bucket
浏览器 → agentteams.cloud → 云原生 API 网关（HTTPS）→ 同地域 OSS 内网域名
```

官网仓库保存源码和公开素材，只上传经过校验的 `dist/` 内容。
仓库名中的 `.github.io` 不要求启用 GitHub Pages。

## 1. 准备 OSS

创建官网专用 Bucket，选择与网关相同的地域。Bucket 名称全局唯一，需填入实际创建的名称。
示例地域为 `cn-hongkong`；选址前确认网关可用规格、预算及域名备案要求。

本文采用阿里云官方静态网站托管指南中的公共读方案：

- Bucket 只保存可公开的网站产物，配置公共读、私有写；按控制台要求处理“阻止公共访问”。
- 静态页面默认首页：`index.html`。
- 开启子目录首页，确保 `/quickstart/` 和 `/docs/architecture/` 返回对应目录的页面。
- 无尾斜杠路径按 OSS 子目录规则重定向至目录，并验证 Location 不泄露内网地址。
- 默认错误页：`404.html`，错误文档响应码：`404`。不把所有不存在路径回退为首页 200。

如果必须使用私有 Bucket，需另行实现并验证网关签名回源；配置内网域名不会自动获得访问权限。

## 2. 配置 GitHub

创建 `website-production` Environment，部署分支只允许 `main`。
如需完全自动发布，不设置人工审批规则；按团队管理要求配置分支保护和必需检查。

| 位置 | 名称 | 值 / 用途 |
| --- | --- | --- |
| Repository variable | `OSS_DEPLOY_ENABLED` | 完成云资源配置后设置为字符串 `true`；未设置时只构建 |
| Environment variable | `OSS_BUCKET` | 官网 Bucket 名，不带 `oss://`、域名或路径 |
| Environment variable | `OSS_REGION` | 例如 `cn-hongkong`，不带 `oss-` 前缀 |
| Environment variable（可选） | `SITE_URL` | 域名和网关就绪后设置 `https://agentteams.cloud`，启用线上验证 |
| Environment secret | `ACCESS_KEYID` | 专用发布 RAM 用户的 AccessKey ID |
| Environment secret | `ACCESS_KEYSECRET` | 对应的 AccessKey Secret |

`OSS_DEPLOY_ENABLED` 必须是仓库级变量，因为 job 是否执行的判断早于 Environment 加载。
其余配置放在 `website-production`。凭证名称与 HiRoute 的官网工作流一致。
本工作流使用专用 RAM 用户，不依赖未配置的 OIDC Provider 或角色。

发布用户只需要指定 Bucket 下对象的 `oss:PutObject` 权限。示例策略中将
`YOUR_WEBSITE_BUCKET` 替换为实际 Bucket 名：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["oss:PutObject"],
      "Resource": ["acs:oss:*:*:YOUR_WEBSITE_BUCKET/*"]
    }
  ]
}
```

不需要授予所有 Bucket 权限、删除权限或 Bucket 配置权限。SDK 使用 HTTPS 和 V4 签名，
GitHub 托管 Runner 通过 OSS 公网端点上传；网关的内网回源属于另一条链路。
Secrets 仅传递给上传步骤，不写入前端、构建产物或命令行参数。

## 3. 配置网关和域名

按 [阿里云官方部署指南](https://help.aliyun.com/zh/api-gateway/cloud-native-api-gateway/use-cases/static-website-hosting-based-on-cloud-native-api-gateway-and-alibaba-cloud-oss) 配置：

1. 为 Bucket 创建 DNS 类型后端服务，例如 `YOUR_WEBSITE_BUCKET.oss-cn-hongkong-internal.aliyuncs.com:80`。
2. 为 `agentteams.cloud` 创建前缀 `/` 的路由，指向上述服务。
3. 将回源 Host 重写为 Bucket 内网域名，而非保留 `agentteams.cloud`。
4. 从响应中移除 `Content-Disposition`，避免网页变成下载文件；保留 OSS 的 `Content-Type` 和 `Cache-Control`。
5. 配置包含 `agentteams.cloud` 的 HTTPS 证书，开启 HTTP 到 HTTPS 的跳转。
6. 核查 DNS 托管和委派正常，再将官网域名解析到网关提供的公网入口。
7. 若提供 `www.agentteams.cloud`，配置相应证书和跳转，将访问统一到主域名。

中国内地部署需核实域名备案和接入要求。创建资源前确认实际账号、地域和费用。
DNS、证书、OSS ACL、网关实例和路由由基础设施侧配置，GitHub 工作流不会创建或修改它们。

## 4. 首次发布与验收

1. 配好 Bucket 和 Environment 的四个必填参数，设置仓库变量 `OSS_DEPLOY_ENABLED=true`。
2. 向 `main` 提交变更，或在 Actions 中对 `main` 执行 `Website` 工作流。
3. 确认 build 和 deploy 成功，OSS 中包含首页、嵌套页面、`_astro/` 资源、`404.html`、`agentteams-install.sh`、`agentteams-dashboard.sh` 及各自的 `.LICENSE` 文件。
4. 网关与正式域名就绪后设置 Environment variable `SITE_URL=https://agentteams.cloud`，再次执行工作流。
5. 线上验证会检查所有正常页面和 CSS/JS、404、安装脚本与许可证的状态、Content-Type、非附件响应，逐字节比对构建产物，并检查脚本的 `no-cache` 响应头。
   网关应直接返回静态内容，不注入或变更页面；若前置缓存不忽略验证查询参数，需同步配置缓存策略。
6. 人工检查桌面与移动端布局、安装命令复制、外部文档链接、HTTP 跳转，以及无尾斜杠路径。

本地也可以在 `dist/` 与目标部署一致时运行：

```bash
SITE_URL=https://agentteams.cloud npm run test:live
```

PR 与其他分支的手动执行不会使用生产凭证或上传。构建和部署 job 都有超时限制，
生产上传串行执行，正在进行的生产发布不会因新提交被取消。

## 5. 缓存、失败和回滚

- `_astro/` 下的构建资源使用 `Cache-Control: public,max-age=31536000,immutable`。
- 两个安装脚本 `agentteams-install.sh`、`agentteams-dashboard.sh` 使用 `no-cache`，每次请求重新验证缓存；Content-Type 为 `text/plain; charset=utf-8`。
- HTML、其余 `public/` 静态素材、robots 和 sitemap 使用 `public,max-age=300`。
- 稳定安装脚本只从已提交的 Release 快照发布，构建会核对校验值和 Bash 语法。升级流程见 [稳定安装脚本维护](installer.md)。
- 所有资源上传完成后才更新 HTML，根首页最后上传。资源上传失败会终止发布，不进入 HTML 阶段。
- 上传不删除旧对象，旧哈希资源可继续服务已打开的页面。删除或改名的页面也会保留，需单独评估后清理。
- 覆盖上传并非整站原子切换；HTML 上传中途失败时可能出现版本交叠。修复后重跑或回滚。
- 线上验证失败时工作流报错，不会自动回滚；先检查实际上传状态和 DNS/网关配置。

每次构建保存 `agentteams-website-<commit SHA>` artifact，默认保留 30 天。
回滚可对上一次成功的 `main` 工作流选择重新运行所有 job，使用其对应提交重新构建并发布。
重新构建会重新解析依赖下载源；若需精确恢复之前的产物，应下载保留的 artifact，
解压到本地 `dist/`，在对应源码提交中通过受控环境注入上述四个部署参数后执行：

```bash
npm ci
npm run deploy:plan
npm run deploy
SITE_URL=https://agentteams.cloud npm run test:live
```

不要把真实密钥写进 shell 历史、文件或文档。产物保留期之外的版本需要额外的归档策略。
若未来需要整站原子切换，再设计版本目录与网关路由切换，不把当前覆盖上传当作原子发布。
