import installerRelease from '../../installer-release.json';
import dashboardInstallerRelease from '../../dashboard-installer-release.json';

export const site = {
  name: 'AgentTeams',
  description: '开源多 Agent 协作平台。让 Manager 协调 Workers，在同一个房间里完成任务，协作过程可见，人类随时参与。',
  repository: 'https://github.com/agentscope-ai/AgentTeams',
  websiteRepository: 'https://github.com/agentteams-group/agentteams-group.github.io',
  dashboardRepository: 'https://github.com/agentteams-group/agentteams-dashboard',
  agentCore: 'https://www.aliyun.com/product/agentcore',
  docs: 'https://github.com/agentscope-ai/AgentTeams/tree/main/docs/zh-cn',
  installVersion: installerRelease.version,
  installCommand: 'curl -fsSL https://agentteams.cloud/agentteams-install.sh | bash',
  dashboardInstallVersion: dashboardInstallerRelease.version,
  dashboardInstallCommand: 'curl -fsSL https://agentteams.cloud/agentteams-dashboard.sh | bash',
};

export const navigation = [
  { href: '/', label: '首页' },
  { href: '/#how-it-works', label: '产品' },
  { href: '/#dashboard', label: 'Dashboard' },
  { href: '/docs/', label: '文档' },
  { href: '/community/', label: '社区' },
];
