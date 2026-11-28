#!/usr/bin/env powershell
# AgentTeams website stable installer: v1.2.8
# Maintained in: https://github.com/agentteams-group/agentteams-group.github.io/blob/main/public/install.ps1
# Originally imported from: https://github.com/agentscope-ai/AgentTeams/blob/d9d39d8ec7caf1f98bfd6c801bf43dd477aa1208/install/agentteams-install.ps1
# Modified: pin the default release and stop on missing versioned embedded images.
# License: https://agentteams.cloud/agentteams-install.LICENSE
# agentteams-install.ps1 - One-click installation for AgentTeams Manager and Worker on Windows
# Requires PowerShell 7.0+ (recommended)
#
# Usage:
#   .\agentteams-install.ps1                  # Start locally and open Dashboard
#   .\agentteams-install.ps1 -Manual          # Customize installation interactively
#   .\agentteams-install.ps1 manager          # Same as above (explicit)
#   .\agentteams-install.ps1 reinstall        # Erase existing installation (typed confirmation)
#   .\agentteams-install.ps1 worker --name <name> ...  # Worker installation
#
# Onboarding Modes:
#   Quick Start  - Fast installation with all default values (recommended)
#   Manual       - Customize each option step by step
#
# Environment variables (for automation):
#   AGENTTEAMS_NON_INTERACTIVE    Skip all prompts, use defaults  (default: 0)
#   AGENTTEAMS_LLM_PROVIDER       LLM provider       (default: openai-compat for zh non-interactive Token Plan; qwen for en)
#   AGENTTEAMS_DEFAULT_MODEL      Default model      (default: qwen3.6-plus for zh Token Plan and en non-interactive)
#   AGENTTEAMS_OPENAI_BASE_URL    OpenAI-compatible base URL (default for zh non-interactive: Alibaba Token Plan endpoint)
#   AGENTTEAMS_LLM_API_KEY        LLM API key        (optional; configure later in Dashboard)
#   AGENTTEAMS_ADMIN_USER         Admin username     (default: admin)
#   AGENTTEAMS_ADMIN_PASSWORD     Admin password     (auto-generated if not set, min 8 chars)
#   AGENTTEAMS_MATRIX_DOMAIN      Matrix domain      (default: matrix-local.agentteams.io:18080)
#   AGENTTEAMS_MOUNT_SOCKET       Mount container runtime socket (default: 1)
#   AGENTTEAMS_MATRIX_E2EE        Matrix E2EE        (default: 0, disabled)
#   AGENTTEAMS_DATA_DIR           Docker volume name for persistent data (default: agentteams-data)
#   AGENTTEAMS_RESOURCE_PREFIX    Docker resource prefix (default: agentteams-; use distinct ports for another instance)
#   AGENTTEAMS_WORKSPACE_DIR      Host directory for manager workspace (default: ~/agentteams-manager)
#   AGENTTEAMS_VERSION            Image tag          (website default: AGENTTEAMS_KNOWN_STABLE_VERSION)
#   AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION DeepSeek Harness runtime image tag (default: selected Core version; explicit overrides supported)
#   AGENTTEAMS_CODEX_WORKER_VERSION Codex runtime image tag (default: selected Core version; explicit overrides supported)
#   AGENTTEAMS_REGISTRY           Image registry     (default: auto-detected by timezone)
#   AGENTTEAMS_HIGRESS_WASM_PLUGIN_REGISTRY
#                                      WASM plugins (default: cn-hangzhou primary)
#   AGENTTEAMS_INSTALL_MANAGER_IMAGE       Override manager image (e.g., local build)
#   AGENTTEAMS_INSTALL_MANAGER_QWENPAW_IMAGE Override QwenPaw manager image (e.g., local build)
#   AGENTTEAMS_INSTALL_MANAGER_COPAW_IMAGE  Override legacy CoPaw manager image (e.g., local build)
#   AGENTTEAMS_INSTALL_WORKER_IMAGE        Override worker image  (e.g., local build)
#   AGENTTEAMS_INSTALL_COPAW_WORKER_IMAGE  Override copaw worker image (e.g., local build)
#   AGENTTEAMS_INSTALL_QWENPAW_WORKER_IMAGE Override qwenpaw worker image (e.g., local build)
#   AGENTTEAMS_INSTALL_HERMES_WORKER_IMAGE Override hermes worker image (e.g., local build)
#   AGENTTEAMS_INSTALL_OPENHUMAN_WORKER_IMAGE Override OpenHuman worker image (e.g., local build)
#   AGENTTEAMS_INSTALL_DEEPSEEK_HARNESS_WORKER_IMAGE Override experimental DeepSeek Harness worker image
#   AGENTTEAMS_INSTALL_CODEX_WORKER_IMAGE Override Codex worker image
#   AGENTTEAMS_PORT_GATEWAY       Host port for Higress gateway (default: 18080)
#   AGENTTEAMS_PORT_CONSOLE       Host port for Higress console (default: 18001)
#   AGENTTEAMS_PORT_ELEMENT_WEB   Host port for Element Web direct access (default: 18088)

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("manager", "worker", "reinstall", "uninstall")]
    [string]$Command = "manager",

    # Worker options
    [string]$Name,
    [string]$Fs,
    [string]$FsKey,
    [string]$FsSecret,
    [switch]$Reset,
    [switch]$FindSkills,
    [string]$SkillsApiUrl,

    # General options
    [switch]$NonInteractive,
    [switch]$Manual,
    [string]$EnvFile
)

# ============================================================
# Configuration
# ============================================================

$script:InstallEnvKeys = @{}
foreach ($key in [Environment]::GetEnvironmentVariables('Process').Keys) { $script:InstallEnvKeys[$key] = $true }
$script:AGENTTEAMS_KNOWN_STABLE_VERSION = "v1.2.8"
$script:AGENTTEAMS_VERSION = if ($env:AGENTTEAMS_VERSION) { $env:AGENTTEAMS_VERSION } else { $script:AGENTTEAMS_KNOWN_STABLE_VERSION }
$script:AGENTTEAMS_DEEPSEEK_HARNESS_MIN_VERSION = "v1.2.4"
$script:AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION = $env:AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION
$script:AGENTTEAMS_CODEX_WORKER_VERSION = $env:AGENTTEAMS_CODEX_WORKER_VERSION
$script:AGENTTEAMS_NON_INTERACTIVE = if ($env:AGENTTEAMS_NON_INTERACTIVE -eq "1" -or $NonInteractive) { $true } else { $false }
$script:AGENTTEAMS_QUICKSTART = -not $Manual -and $env:AGENTTEAMS_QUICKSTART -ne "0"
$script:AGENTTEAMS_MOUNT_SOCKET = if ($env:AGENTTEAMS_MOUNT_SOCKET -eq "0") { $false } else { $true }
function Initialize-ResourceNames {
    $prefix = if ($env:AGENTTEAMS_RESOURCE_PREFIX) { $env:AGENTTEAMS_RESOURCE_PREFIX } else { 'agentteams-' }
    $script:AGENTTEAMS_ENV_FILE = if ($EnvFile) { $EnvFile } elseif ($env:AGENTTEAMS_ENV_FILE) { $env:AGENTTEAMS_ENV_FILE } else { "$env:USERPROFILE\${prefix}manager.env" }
    if (Test-Path -LiteralPath $script:AGENTTEAMS_ENV_FILE) {
        $saved = Get-Content -LiteralPath $script:AGENTTEAMS_ENV_FILE | Where-Object { $_ -match '^AGENTTEAMS_RESOURCE_PREFIX=' } | Select-Object -Last 1
        if ($saved) {
            $savedPrefix = ($saved -split '=', 2)[1].Trim()
            if ($env:AGENTTEAMS_RESOURCE_PREFIX -and $savedPrefix -ne $prefix) { throw "Resource prefix does not match $($script:AGENTTEAMS_ENV_FILE)" }
            $prefix = $savedPrefix
        }
    }
    if ($prefix -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$') { throw "Invalid AGENTTEAMS_RESOURCE_PREFIX: $prefix" }
    $script:AGENTTEAMS_RESOURCE_PREFIX = $prefix
    $script:MANAGER_CONTAINER = "${prefix}manager"
    $script:CONTROLLER_CONTAINER = "${prefix}controller"
    $script:DASHBOARD_CONTAINER = "${prefix}dashboard"
    $script:DOCKER_PROXY_CONTAINER = "${prefix}docker-proxy"
    $script:WORKER_CONTAINER_PREFIX = "${prefix}worker-"
    $script:DOCKER_NETWORK = "${prefix}net"
    $script:DEFAULT_DATA_VOLUME = "${prefix}data"
    $script:DASHBOARD_VOLUME = "${prefix}dashboard-data"
}
Initialize-ResourceNames
$script:StepResult = ""  # Used by state machine to signal "back" navigation
$script:config = @{}     # Shared config hashtable for step functions
$script:ModelConnectionStatus = 'unknown'

# ANSI escape character for terminal colors
$script:ESC = [char]0x1B

# ============================================================
# Log all output to file
# ============================================================

$script:AGENTTEAMS_LOG_FILE = "$env:USERPROFILE\$($script:AGENTTEAMS_RESOURCE_PREFIX)install.log"

# Start transcript for logging (PowerShell's built-in logging mechanism)
try {
    Start-Transcript -Path $script:AGENTTEAMS_LOG_FILE -Append -ErrorAction SilentlyContinue | Out-Null
} catch {
    # If transcript fails, continue without logging
}


# ============================================================
# Utility Functions
# ============================================================

function Write-Log {
    param([string]$Message)
    Write-Host "$($script:ESC)[36m[AgentTeams]$($script:ESC)[0m $Message"
}

function Invoke-DockerLogged {
    param([string[]]$DockerArgs)
    $output = (& docker @DockerArgs 2>&1 | Out-String)
    $exitCode = $LASTEXITCODE
    if ($output) { Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value $output }
    if ($exitCode -ne 0) { Write-Host $output -ForegroundColor Red }
    $global:LASTEXITCODE = $exitCode
}

function Show-InstallSummary {
    Write-Log ""
    Write-Log (Get-Msg 'success.title')
    if ($script:AGENTTEAMS_DASHBOARD_READY) {
        Write-Log (Get-Msg 'output.dashboard_url' -f (Get-DashboardBrowserUrl))
    } elseif ($script:config.UNIFIED_ENTRY -eq '1') {
        Write-Log "AgentTeams: $(Get-UnifiedEntryUrl)"
    } else {
        $port = if ($script:config.PORT_ELEMENT_WEB) { $script:config.PORT_ELEMENT_WEB } else { '18088' }
        Write-Log (Get-Msg 'output.element_url' -f "http://127.0.0.1:${port}/#/login")
    }
    Write-Log (Get-Msg 'success.username' -f $script:config.ADMIN_USER)
    Write-Log (Get-Msg 'success.password' -f $script:config.ADMIN_PASSWORD)
    Write-Log ""
    switch ($script:ModelConnectionStatus) {
        'ready' {
            Write-Log (Get-Msg 'output.model_ready')
            Write-Log (Get-Msg 'output.next_ready')
        }
        'unavailable' {
            Write-Log (Get-Msg 'output.model_unavailable')
        }
        default {
            Write-Log (Get-Msg 'output.model_unverified')
        }
    }
    if ($script:ModelConnectionStatus -ne 'ready') {
        $nextStep = if ($script:AGENTTEAMS_DASHBOARD_READY) { 'output.next_model' } else { 'output.next_model_other' }
        Write-Log (Get-Msg $nextStep)
    }
    if ($script:config.LOCAL_ONLY -ne '0') {
        Write-Log (Get-Msg 'output.local_only')
    } else {
        Write-Log (Get-Msg 'output.lan_enabled')
        $lanIP = Get-LanIP
        if ($lanIP) {
            if ($script:AGENTTEAMS_DASHBOARD_READY) {
                $dashboardUrl = if ($script:config.UNIFIED_ENTRY -eq '1') { Get-DashboardBrowserUrl } else { "http://${lanIP}:$($script:config.PORT_DASHBOARD)/" }
                Write-Log (Get-Msg 'output.lan_dashboard' -f $dashboardUrl)
            }
            Write-Log (Get-Msg 'output.mobile_server' -f "http://${lanIP}:$($script:config.PORT_GATEWAY)")
        }
    }
    Write-Log ""
    if ($script:AGENTTEAMS_ENV_FILE) { Write-Log (Get-Msg 'success.config_file' -f $script:AGENTTEAMS_ENV_FILE) }
    if ($script:AGENTTEAMS_LOG_FILE) { Write-Log (Get-Msg 'output.log_file' -f $script:AGENTTEAMS_LOG_FILE) }
}

function Update-InstalledManagerImage {
    param([string]$Image)
    $runtimeArgs = @()
    if ($script:config.MANAGER_RUNTIME) { $runtimeArgs = @('--runtime', $script:config.MANAGER_RUNTIME) }
    Write-Log (Get-Msg 'output.update_manager')
    for ($elapsed = 0; $elapsed -lt 60; $elapsed += 2) {
        $output = (docker exec $script:CONTROLLER_CONTAINER agt update manager --name default --image $Image @runtimeArgs 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
        if ($output) { Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value $output }
        if ($exitCode -eq 0) { return }
        Start-Sleep -Seconds 2
    }
    Write-Error (Get-Msg 'output.update_manager_failed' -f $script:AGENTTEAMS_LOG_FILE)
}

function Write-Error {
    param([string]$Message)
    Write-Host "$($script:ESC)[31m[AgentTeams ERROR]$($script:ESC)[0m $Message" -ForegroundColor Red
    throw $Message
}

function Write-Warning {
    param([string]$Message)
    Write-Host "$($script:ESC)[33m[AgentTeams WARNING]$($script:ESC)[0m $Message"
}

function Update-AgentTeamsKnownStableVersion {
    if ($script:AGENTTEAMS_VERSION -ne "latest") { return }
    try {
        $release = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/agentscope-ai/AgentTeams/releases/latest" `
            -Headers @{ "Accept" = "application/vnd.github+json"; "User-Agent" = "AgentTeams-Installer" } `
            -TimeoutSec 5 `
            -ErrorAction Stop
        $tag = [string]$release.tag_name
        if ($tag -match '^v\d+\.\d+\.\d+$') {
            $script:AGENTTEAMS_KNOWN_STABLE_VERSION = $tag
        }
    } catch {
        # Keep the bundled fallback when GitHub is unavailable.
    }
}

function ConvertTo-MatrixAppServiceEnabledValue {
    param([string]$Value)
    return $Value.ToLowerInvariant()
}

function Test-DeepSeekHarnessAvailable {
    $hasWorkerOverride = -not [string]::IsNullOrWhiteSpace($env:AGENTTEAMS_INSTALL_DEEPSEEK_HARNESS_WORKER_IMAGE)
    $hasEmbeddedOverride = -not [string]::IsNullOrWhiteSpace($env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE)
    if ($hasWorkerOverride -and $hasEmbeddedOverride) { return $true }
    $selected = if ($script:AGENTTEAMS_VERSION -eq "latest") {
        $script:AGENTTEAMS_KNOWN_STABLE_VERSION
    } else {
        $script:AGENTTEAMS_VERSION
    }
    $selectedMatch = [regex]::Match($selected, '^v?(\d+\.\d+\.\d+)')
    $minimumMatch = [regex]::Match($script:AGENTTEAMS_DEEPSEEK_HARNESS_MIN_VERSION, '^v?(\d+\.\d+\.\d+)')
    if (-not $selectedMatch.Success -or -not $minimumMatch.Success) { return $false }
    return [version]$selectedMatch.Groups[1].Value -ge [version]$minimumMatch.Groups[1].Value
}

# Pause before exit on error so user can read the message when running via double-click
function Exit-Script {
    param([int]$ExitCode = 0)
    if ($ExitCode -ne 0 -and -not $script:AGENTTEAMS_NON_INTERACTIVE) {
        Write-Host ""
        Write-Host "Press Enter to exit." -NoNewline
        $Host.UI.ReadLine()
    }
    exit $ExitCode
}

function Test-DockerRunning {
    try {
        $null = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-AgentTeamsTimeZone {
    try {
        if ($env:AGENTTEAMS_TIMEZONE) {
            return $env:AGENTTEAMS_TIMEZONE
        }

        $tz = (Get-TimeZone).Id
        # Convert Windows timezone to IANA format
        $tzMap = @{
            "China Standard Time" = "Asia/Shanghai"
            "Pacific Standard Time" = "America/Los_Angeles"
            "Mountain Standard Time" = "America/Denver"
            "Central Standard Time" = "America/Chicago"
            "Eastern Standard Time" = "America/New_York"
            "GMT Standard Time" = "Europe/London"
            "Central European Standard Time" = "Europe/Berlin"
            "Tokyo Standard Time" = "Asia/Tokyo"
            "Singapore Standard Time" = "Asia/Singapore"
            "Korea Standard Time" = "Asia/Seoul"
            "India Standard Time" = "Asia/Kolkata"
        }

        if ($tzMap.ContainsKey($tz)) {
            return $tzMap[$tz]
        }
        return $tz
    }
    catch {
        return "Asia/Shanghai"
    }
}

function Get-Registry {
    param([string]$Timezone)

    if ($env:AGENTTEAMS_REGISTRY) {
        return $env:AGENTTEAMS_REGISTRY
    }

    # Americas
    if ($Timezone -match "^America/") {
        return "higress-registry.us-west-1.cr.aliyuncs.com"
    }

    # Southeast Asia
    if ($Timezone -match "^(Asia/Singapore|Asia/Bangkok|Asia/Jakarta|Asia/Makassar|Asia/Jayapura|Asia/Kuala_Lumpur|Asia/Ho_Chi_Minh|Asia/Manila|Asia/Yangon|Asia/Vientiane|Asia/Phnom_Penh|Asia/Pontianak|Asia/Ujung_Pandang)") {
        return "higress-registry.ap-southeast-7.cr.aliyuncs.com"
    }

    # Default: China
    return "higress-registry.cn-hangzhou.cr.aliyuncs.com"
}

function Get-AgentTeamsLanguage {
    param([string]$Timezone)
    $chineseZones = @(
        "Asia/Shanghai", "Asia/Chongqing", "Asia/Harbin", "Asia/Urumqi",
        "Asia/Taipei", "Asia/Hong_Kong", "Asia/Macau"
    )
    if ($chineseZones -contains $Timezone) { return "zh" }
    return "en"
}

# ============================================================
# Centralized message dictionary and Get-Msg function
# ============================================================

$script:Messages = @{
    "output.update_manager" = @{ zh = "更新 Manager 镜像..."; en = "Updating Manager image..." }
    "output.update_manager_failed" = @{ zh = "Manager 镜像更新失败，请查看详细日志：{0}"; en = "Manager image update failed. Check the detailed log: {0}" }
    "output.next_model_other" = @{ zh = "请先检查模型配置，再开始对话。"; en = "Check your model settings before starting a conversation." }
    "output.runtime_missing" = @{ zh = "Docker 尚未就绪。请安装并打开 Docker Desktop，等待引擎启动。"; en = "Docker is not ready. Install Docker Desktop, open it, and wait until the engine is running." }
    "output.runtime_setup" = @{ zh = "如果 Docker 提示安装 WSL 2 或重启，请完成后重新运行安装命令。"; en = "If Docker asks for WSL 2 or a restart, complete setup, then run this install command again." }
    "output.runtime_wait" = @{ zh = "最多等待 15 分钟，每 3 秒检查一次。按 Ctrl+C 取消。"; en = "Waiting up to 15 minutes; checking every 3 seconds. Press Ctrl+C to cancel." }
    "output.runtime_progress" = @{ zh = "等待 Docker/Podman 就绪（已等待 {0}s，最多 900s）..."; en = "Still waiting for Docker/Podman ({0}s / 900s). Start your container engine to continue." }
    "output.dashboard_url" = @{ zh = "Dashboard 访问地址：{0}"; en = "Dashboard URL: {0}" }
    "output.element_url" = @{ zh = "Element Web 访问地址：{0}"; en = "Element Web URL: {0}" }
    "output.model_ready" = @{ zh = "模型连接：检查已通过"; en = "Model connection: check passed" }
    "output.model_unavailable" = @{ zh = "模型连接：暂不可用，基础服务已启动"; en = "Model connection: unavailable; core services are running" }
    "output.model_unverified" = @{ zh = "模型连接：尚未验证"; en = "Model connection: not verified" }
    "output.next_model" = @{ zh = "请登录 Dashboard，检查模型配置后再开始对话。"; en = "Sign in to Dashboard and check your model settings before starting a conversation." }
    "output.next_ready" = @{ zh = "请登录上方界面开始使用。"; en = "Sign in at the URL above to get started." }
    "output.local_only" = @{ zh = "访问范围：仅本机"; en = "Access: localhost only" }
    "output.lan_enabled" = @{ zh = "访问范围：已允许局域网访问"; en = "Access: LAN access enabled" }
    "output.lan_dashboard" = @{ zh = "局域网 Dashboard：{0}"; en = "LAN Dashboard: {0}" }
    "output.mobile_server" = @{ zh = "手机 IM 客户端的 Matrix 服务地址：{0}"; en = "Matrix server for mobile IM clients: {0}" }
    "output.log_file" = @{ zh = "详细日志：{0}"; en = "Detailed log: {0}" }
    "output.start_core" = @{ zh = "启动基础服务..."; en = "Starting core services..." }
    "output.core_started" = @{ zh = "基础服务容器已启动"; en = "Core services container started" }
    "output.wait_service" = @{ zh = "等待 {0} 就绪..."; en = "Waiting for {0}..." }
    "output.service_ready" = @{ zh = "{0} 已就绪（{1}s）"; en = "{0} is ready ({1}s)" }
    "output.service_timeout" = @{ zh = "{0} 在 {1}s 内未就绪"; en = "{0} is not ready after {1}s" }
    "output.wait_manager" = @{ zh = "等待 Manager 容器启动..."; en = "Waiting for the Manager container..." }
    "output.manager_detected" = @{ zh = "Manager 容器已启动（{0}s）"; en = "Manager container started ({0}s)" }
    "output.manager_timeout" = @{ zh = "Manager 容器在 {0}s 内未启动"; en = "Manager container did not start within {0}s" }
    "output.start_dashboard" = @{ zh = "启动 Dashboard..."; en = "Starting Dashboard..." }
    "output.dashboard_ready" = @{ zh = "Dashboard 已就绪"; en = "Dashboard is ready" }
    "output.dashboard_timeout" = @{ zh = "Dashboard 未按时就绪，请查看详细日志。"; en = "Dashboard startup timed out. Check the detailed log." }
    "output.backup" = @{ zh = "已备份原安装配置"; en = "Existing installation settings backed up" }
    "output.pull_retry" = @{ zh = "镜像下载失败，5 秒后重试（{0}/3）..."; en = "Image download failed; retrying in 5s ({0}/3)..." }
    "output.pull_failed" = @{ zh = "镜像准备失败，请查看详细日志：{0}"; en = "Image preparation failed. Check the detailed log: {0}" }
    "output.manual_browser" = @{ zh = "请在浏览器中打开上方访问地址。"; en = "Open the URL shown above in your browser." }
    "output.check_image" = @{ zh = "检查运行平台所需的镜像..."; en = "Checking images for the container platform..." }
    "upgrade.summary" = @{ zh = "保留数据升级：{0} → {1}。保留账号、模型配置、聊天记录和工作空间；核心服务将短暂中断。"; en = "Upgrade with data preserved: {0} → {1}. Accounts, models, messages and workspaces are retained; core services will briefly restart." }
    "upgrade.confirm" = @{ zh = "继续升级？[Y/n]"; en = "Continue upgrading? [Y/n]" }
    "upgrade.recovered" = @{ zh = "已从现有容器恢复安装配置，将复用原数据卷和工作空间。"; en = "Recovered settings from the existing container; original storage and workspace will be reused." }
    "upgrade.recovery_failed" = @{ zh = "发现已有安装数据，但无法完整恢复配置。已停止，不会清理或替换原数据。请恢复 agentteams-manager.env 后重试。"; en = "Existing data found, but configuration could not be fully recovered. Stopped without deleting or replacing data. Restore agentteams-manager.env and retry." }
    # --- Timezone detection messages ---
    "tz.warning.title" = @{ zh = "无法自动检测时区。"; en = "Could not detect timezone automatically." }
    "tz.warning.prompt" = @{ zh = "请输入您的时区（例如 Asia/Shanghai、America/New_York）。"; en = "Please enter your timezone (e.g., Asia/Shanghai, America/New_York)." }
    "tz.default" = @{ zh = "使用默认时区: {0}"; en = "Using default timezone: {0}" }
    "tz.input_prompt" = @{ zh = "时区"; en = "Timezone" }

    # --- Installation title and info ---
    "install.title" = @{ zh = "=== AgentTeams 安装 ==="; en = "=== AgentTeams Installation ===" }
    "install.registry" = @{ zh = "镜像仓库: {0}"; en = "Registry: {0}" }
    "install.dir" = @{ zh = "安装目录: {0}"; en = "Installation directory: {0}" }
    "install.dir_hint" = @{ zh = "  （env 文件 'agentteams-manager.env' 将保存到 HOME 目录。）"; en = "  (The env file 'agentteams-manager.env' will be saved to your HOME directory.)" }
    "install.dir_hint2" = @{ zh = "  （请从您希望管理此安装的目录运行此脚本。）"; en = "  (Run this script from the directory where you want to manage this installation.)" }

    # --- Onboarding mode ---
    "install.mode.title" = @{ zh = "--- Onboarding 模式 ---"; en = "--- Onboarding Mode ---" }
    "install.mode.choose" = @{ zh = "选择安装模式:"; en = "Choose your installation mode:" }
    "install.mode.quickstart" = @{ zh = "  1) 快速开始  - 使用阿里云通义 Token 套餐快速安装（推荐）"; en = "  1) Quick Start  - Fast installation with Qwen Cloud (recommended)" }
    "install.mode.manual" = @{ zh = "  2) 手动配置  - 选择 LLM 提供商并自定义选项"; en = "  2) Manual       - Choose LLM provider and customize options" }
    "install.mode.prompt" = @{ zh = "请选择 [1/2]"; en = "Enter choice [1/2]" }
    "install.mode.quickstart_selected" = @{ zh = "已选择快速开始模式 - 使用阿里云通义 Token 套餐"; en = "Quick Start mode selected - using Qwen Cloud" }
    "install.mode.manual_selected" = @{ zh = "已选择手动配置模式 - 您将选择 LLM 提供商并自定义选项"; en = "Manual mode selected - you will choose LLM provider and customize options" }
    "install.mode.invalid" = @{ zh = "无效选择，默认使用快速开始模式"; en = "Invalid choice, defaulting to Quick Start mode" }

    # --- Existing installation detected ---
    "install.existing.detected" = @{ zh = "检测到已有 Manager 安装（env 文件: {0}）"; en = "Existing Manager installation detected (env file: {0})" }
    "install.existing.choose" = @{ zh = "选择操作:"; en = "Choose an action:" }
    "install.existing.upgrade" = @{ zh = "  1) 就地升级（保留数据、工作空间、env 文件）"; en = "  1) In-place upgrade (keep data, workspace, env file)" }
    "install.existing.reinstall" = @{ zh = "  2) 全新重装（删除所有数据，重新开始）"; en = "  2) Clean reinstall (remove all data, start fresh)" }
    "install.existing.cancel" = @{ zh = "  3) 取消"; en = "  3) Cancel" }
    "install.existing.prompt" = @{ zh = "请选择 [1/2/3]"; en = "Enter choice [1/2/3]" }
    "install.existing.upgrade_noninteractive" = @{ zh = "非交互模式: 执行就地升级..."; en = "Non-interactive mode: performing in-place upgrade..." }
    "install.existing.upgrading" = @{ zh = "执行就地升级..."; en = "Performing in-place upgrade..." }
    "install.existing.warn_manager_stop" = @{ zh = "警告: Manager 容器将被停止并重新创建。"; en = "WARNING: Manager container will be stopped and recreated." }
    "install.existing.warn_worker_recreate" = @{ zh = "警告: Worker 容器也将被重新创建（以更新 Manager IP）。"; en = "WARNING: Worker containers will also be recreated (to update Manager IP in hosts)." }
    "install.existing.continue_prompt" = @{ zh = "继续？[y/N]"; en = "Continue? [y/N]" }
    "install.existing.cancelled" = @{ zh = "安装已取消。"; en = "Installation cancelled." }
    "install.existing.stopping_manager" = @{ zh = "停止并移除现有 manager 容器..."; en = "Stopping and removing existing manager container..." }
    "install.existing.stopping_workers" = @{ zh = "停止并移除现有 worker 容器..."; en = "Stopping and removing existing worker containers..." }
    "install.existing.removed" = @{ zh = "  已移除: {0}"; en = "  Removed: {0}" }

    # --- Upgrade mode sub-menu ---
    "upgrade.mode.prompt" = @{ zh = "请选择升级方式："; en = "Select upgrade mode:" }
    "upgrade.mode.keep_all" = @{ zh = "  1) 保留所有参数，一键升级（推荐）"; en = "  1) Keep all parameters, quick upgrade (recommended)" }
    "upgrade.mode.confirm_each" = @{ zh = "  2) 逐个确认参数（可修改）"; en = "  2) Confirm each parameter (can modify)" }
    "upgrade.mode.back" = @{ zh = "  3) 返回"; en = "  3) Back" }

    # --- Clean reinstall messages ---
    "install.reinstall.performing" = @{ zh = "执行全新重装..."; en = "Performing clean reinstall..." }
    "install.reinstall.warn_stop" = @{ zh = "警告: 以下运行中的容器将被停止:"; en = "WARNING: The following running containers will be stopped:" }
    "install.reinstall.warn_delete" = @{ zh = "警告: 以下内容将被删除:"; en = "WARNING: This will DELETE the following:" }
    "install.reinstall.warn_volume" = @{ zh = "   - Docker 卷: $($script:DEFAULT_DATA_VOLUME)"; en = "   - Docker volume: $($script:DEFAULT_DATA_VOLUME)" }
    "install.reinstall.warn_env" = @{ zh = "   - Env 文件: {0}"; en = "   - Env file: {0}" }
    "install.reinstall.warn_workspace" = @{ zh = "   - Manager 工作空间: {0}"; en = "   - Manager workspace: {0}" }
    "install.reinstall.warn_workers" = @{ zh = "   - 所有 worker 容器"; en = "   - All worker containers" }
    "install.reinstall.warn_proxy" = @{ zh = "   - Docker API 代理容器: $($script:CONTROLLER_CONTAINER)"; en = "   - Docker API proxy container: $($script:CONTROLLER_CONTAINER)" }
    "install.reinstall.removing_proxy" = @{ zh = "正在移除 Docker API 代理容器: $($script:CONTROLLER_CONTAINER)"; en = "Removing Docker API proxy container: $($script:CONTROLLER_CONTAINER)" }
    "install.reinstall.warn_network" = @{ zh = "   - Docker 网络: $($script:DOCKER_NETWORK)"; en = "   - Docker network: $($script:DOCKER_NETWORK)" }
    "install.reinstall.removing_network" = @{ zh = "正在移除 Docker 网络: $($script:DOCKER_NETWORK)"; en = "Removing Docker network: $($script:DOCKER_NETWORK)" }
    "install.reinstall.confirm_type" = @{ zh = "请输入工作空间路径以确认删除（或按 Ctrl+C 取消）:"; en = "To confirm deletion, please type the workspace path:" }
    "install.reinstall.confirm_path" = @{ zh = "输入路径以确认（或按 Ctrl+C 取消）"; en = "Type the path to confirm (or press Ctrl+C to cancel)" }
    "install.reinstall.path_mismatch" = @{ zh = "路径不匹配。中止重装。输入: '{0}'，期望: '{1}'"; en = "Path mismatch. Aborting reinstall. Input: '{0}', Expected: '{1}'" }
    "install.reinstall.confirmed" = @{ zh = "已确认。正在清理..."; en = "Confirmed. Cleaning up..." }
    "install.reinstall.removed_worker" = @{ zh = "  已移除 worker: {0}"; en = "  Removed worker: {0}" }
    "install.reinstall.removing_volume" = @{ zh = "正在移除 Docker 卷: $($script:DEFAULT_DATA_VOLUME)"; en = "Removing Docker volume: $($script:DEFAULT_DATA_VOLUME)" }
    "install.reinstall.warn_volume_fail" = @{ zh = "  警告: 无法移除卷（可能有引用）"; en = "  Warning: Could not remove volume (may have references)" }
    "install.reinstall.removing_workspace" = @{ zh = "正在移除工作空间目录: {0}"; en = "Removing workspace directory: {0}" }
    "install.reinstall.removing_env" = @{ zh = "正在移除 env 文件: {0}"; en = "Removing env file: {0}" }
    "install.reinstall.cleanup_done" = @{ zh = "清理完成。开始全新安装..."; en = "Cleanup complete. Starting fresh installation..." }
    "install.reinstall.failed_rm_workspace" = @{ zh = "无法移除工作空间目录"; en = "Failed to remove workspace directory" }

    # --- Orphan volume detection ---
    "install.orphan_volume.detected" = @{ zh = "⚠️  检测到残留数据卷 '{0}'，但未找到对应的 env 配置文件。"; en = "⚠️  Found leftover data volume '{0}' but no matching env config file." }
    "install.orphan_volume.warn" = @{ zh = "这可能是之前安装的残留数据，会导致新安装出现异常（如密码冲突、服务启动失败）。"; en = "This is likely leftover data from a previous installation and may cause issues (e.g., credential conflicts, service startup failures)." }
    "install.orphan_volume.choose" = @{ zh = "选择操作:"; en = "Choose an action:" }
    "install.orphan_volume.clean" = @{ zh = "  1) 清理残留数据卷后继续安装（推荐）"; en = "  1) Remove leftover volume and continue installation (recommended)" }
    "install.orphan_volume.keep" = @{ zh = "  2) 保留数据卷继续安装（可能出现异常）"; en = "  2) Keep the volume and continue installation (may cause issues)" }
    "install.orphan_volume.prompt" = @{ zh = "请选择 [1/2]"; en = "Enter choice [1/2]" }
    "install.orphan_volume.cleaning" = @{ zh = "正在清理残留数据卷..."; en = "Removing leftover data volume..." }
    "install.orphan_volume.cleaned" = @{ zh = "残留数据卷已清理。继续全新安装..."; en = "Leftover volume removed. Continuing with fresh installation..." }
    "install.orphan_volume.keeping" = @{ zh = "保留数据卷，继续安装。如遇异常请选择全新重装。"; en = "Keeping existing volume. If you encounter issues, consider a clean reinstall." }
    "install.orphan_volume.clean_noninteractive" = @{ zh = "非交互模式: 自动清理残留数据卷..."; en = "Non-interactive mode: automatically removing leftover volume..." }

    # --- Loading existing config ---
    "install.loading_config" = @{ zh = "从 {0} 加载已有配置（shell 环境变量优先）..."; en = "Loading existing config from {0} (shell env vars take priority)..." }

    # --- LLM Configuration ---
    "llm.title" = @{ zh = "--- LLM 配置 ---"; en = "--- LLM Configuration ---" }
    "llm.provider.label" = @{ zh = "  提供商: {0}"; en = "  Provider: {0}" }
    "llm.model.label" = @{ zh = "  模型: {0}"; en = "  Model: {0}" }
    "llm.provider.qwen" = @{ zh = "  提供商: qwen（阿里云百炼）"; en = "  Provider: qwen (Alibaba Cloud Bailian)" }
    "llm.provider.qwen_default" = @{ zh = "  提供商: {0}（默认）"; en = "  Provider: {0} (default)" }
    "llm.model.default" = @{ zh = "  模型: {0}（默认）"; en = "  Model: {0} (default)" }
    "llm.apikey_hint_bailian" = @{ zh = "  提示: 获取阿里云百炼（DashScope）API Key:"; en = "  Hint: Get your Alibaba Cloud Bailian (DashScope) API Key:" }
    "llm.apikey_url_bailian" = @{ zh = "     https://www.aliyun.com/product/bailian"; en = "     https://www.aliyun.com/product/bailian" }
    "llm.apikey_hint_qwencloud" = @{ zh = "  提示: 从 Qwen Cloud（国际站）获取 DASHSCOPE_API_KEY:"; en = "  Hint: Get your DASHSCOPE_API_KEY for Qwen Cloud (international) from:" }
    "llm.apikey_url_qwencloud" = @{ zh = "     https://home.qwencloud.com/api-keys  （文档: https://docs.qwencloud.com/）"; en = "     https://home.qwencloud.com/api-keys  |  Docs: https://docs.qwencloud.com/" }
    "llm.apikey_hint_tokenplan" = @{ zh = "  提示: 获取 DashScope API Key 或开通通义 Token 套餐，请参考:"; en = "  Hint: Get your DashScope or Token Plan API key (Alibaba Model Studio):" }
    "llm.apikey_url_tokenplan" = @{ zh = "     https://help.aliyun.com/zh/model-studio/token-plan-quickstart"; en = "     https://common-buy.aliyun.com/token-plan/  |  https://help.aliyun.com/zh/model-studio/token-plan-quickstart" }
    "llm.apikey_hint_codingplan" = @{ zh = "  提示: 获取 DashScope API Key（Coding 套餐 / coding.dashscope 接口）:"; en = "  Hint: Get your DashScope API key for Coding Plan (coding.dashscope endpoint):" }
    "llm.apikey_url_codingplan" = @{ zh = "     https://help.aliyun.com/zh/model-studio/get-api-key"; en = "     https://help.aliyun.com/zh/model-studio/get-api-key" }
    "llm.apikey_prompt" = @{ zh = "LLM API Key"; en = "LLM API Key" }
    "llm.providers_title" = @{ zh = "可用 LLM 提供商:"; en = "Available LLM Providers:" }
    "llm.provider.alibaba" = @{ zh = "  1) 阿里云通义 Token 套餐  - 推荐中国用户使用"; en = "  1) Qwen Cloud  - International (OpenAI-compatible API, recommended)" }
    "llm.provider.openai_compat" = @{ zh = "  2) OpenAI 兼容 API  - 自定义 Base URL（OpenAI、DeepSeek 等）"; en = "  2) OpenAI-compatible API  - Custom Base URL (OpenAI, DeepSeek, etc.)" }
    "llm.provider.select" = @{ zh = "选择提供商 [1/2]"; en = "Select provider [1/2]" }
    "llm.alibaba.models_title" = @{ zh = "选择阿里云模型接入方式:"; en = "Select Alibaba Cloud model access:" }
    "llm.alibaba.model.tokenplan" = @{ zh = "  1) 阿里云通义 Token 套餐  - 兼容模式（推荐）"; en = "  1) Alibaba Cloud Token Plan  - compatible-mode (recommended)" }
    "llm.alibaba.model.bailian" = @{ zh = "  2) 阿里云百炼  - DashScope 通用兼容接口"; en = "  2) Alibaba Cloud Bailian  - DashScope compatible mode" }
    "llm.alibaba.model.codingplan_legacy" = @{ zh = "  3) 阿里云 Coding 套餐  - 旧版端点（兼容保留）"; en = "  3) Alibaba Cloud Coding Plan  - legacy endpoint (backward compatible)" }
    "llm.alibaba.model.select" = @{ zh = "选择接入方式 [1/2/3]"; en = "Select access option [1/2/3]" }
    "llm.alibaba.model.invalid" = @{ zh = "无效选择: {0}（请输入 1、2 或 3）"; en = "Invalid choice: {0} (please enter 1, 2, or 3)" }
    "llm.codingplan.models_title" = @{ zh = "选择通义 Token 套餐默认模型:"; en = "Select Qwen Cloud default model:" }
    "llm.codingplan.model.qwen36plus" = @{ zh = "  1) qwen3.6-plus  - 千问 3.6（推荐）"; en = "  1) qwen3.6-plus  - Qwen 3.6 (recommended)" }
    "llm.codingplan.model.glm5" = @{ zh = "  2) glm-5.2  - 智谱 GLM-5.2（编程推荐）"; en = "  2) glm-5.2  - Zhipu GLM-5.2 (recommended for coding)" }
    "llm.codingplan.model.kimi" = @{ zh = "  3) kimi-k2.5  - Moonshot Kimi K2.5"; en = "  3) kimi-k2.5  - Moonshot Kimi K2.5" }
    "llm.codingplan.model.minimax" = @{ zh = "  4) MiniMax-M2.5  - MiniMax M2.5"; en = "  4) MiniMax-M2.5  - MiniMax M2.5" }
    "llm.codingplan.model.select" = @{ zh = "选择模型 [1/2/3/4]"; en = "Select model [1/2/3/4]" }
    "llm.provider.selected_tokenplan" = @{ zh = "  提供商: 阿里云通义 Token 套餐（兼容模式）"; en = "  Provider: Alibaba Cloud Token Plan (compatible mode)" }
    "llm.provider.selected_codingplan" = @{ zh = "  提供商: 阿里云通义 Token 套餐（alibaba-cloud）"; en = "  Provider: Qwen Cloud (international) (alibaba-cloud)" }
    "llm.provider.selected_codingplan_legacy" = @{ zh = "  提供商: 阿里云 Coding 套餐（coding.dashscope）"; en = "  Provider: Alibaba Cloud Coding Plan (coding.dashscope)" }
    "llm.provider.selected_qwen" = @{ zh = "  提供商: 阿里云百炼"; en = "  Provider: Alibaba Cloud Bailian" }
    "llm.provider.selected_openai" = @{ zh = "  提供商: {0}（OpenAI 兼容）"; en = "  Provider: {0} (OpenAI-compatible)" }
    "llm.provider.invalid" = @{ zh = "无效选择: {0}（请输入 1 或 2）"; en = "Invalid choice: {0} (please enter 1 or 2)" }
    "llm.qwen.model_prompt" = @{ zh = "默认模型 ID"; en = "Default Model ID" }
    "llm.openai.base_url_prompt" = @{ zh = "Base URL"; en = "Base URL" }
    "llm.openai.model_prompt" = @{ zh = "默认模型 ID"; en = "Default Model ID" }
    "llm.openai.base_url_label" = @{ zh = "  Base URL: {0}"; en = "  Base URL: {0}" }

    # --- Custom model parameters ---
    "llm.custom_model.detected" = @{ zh = "  ⚠️  模型 '{0}' 不在内置模型列表中，请配置模型参数:"; en = "  ⚠️  Model '{0}' is not in the built-in model list. Please configure model parameters:" }
    "llm.custom_model.context_prompt" = @{ zh = "最大上下文长度（token 数）[150000]"; en = "Max context window (tokens) [150000]" }
    "llm.custom_model.max_tokens_prompt" = @{ zh = "最大输出长度（token 数）[128000]"; en = "Max output tokens [128000]" }
    "llm.custom_model.reasoning_prompt" = @{ zh = "是否支持推理/思考模式？[Y/n]"; en = "Does it support reasoning/thinking mode? [Y/n]" }
    "llm.custom_model.vision_prompt" = @{ zh = "是否支持图片输入？[y/N]"; en = "Does it support image input? [y/N]" }
    "llm.custom_model.summary" = @{ zh = "  自定义模型参数: 上下文={0}, 最大输出={1}, 推理={2}, 图片={3}"; en = "  Custom model params: context={0}, maxTokens={1}, reasoning={2}, vision={3}" }

    # --- Admin Credentials ---
    "admin.title" = @{ zh = "--- 管理员凭据 ---"; en = "--- Admin Credentials ---" }
    "admin.username_prompt" = @{ zh = "管理员用户名（至少 3 个字符）"; en = "Admin Username (min 3 characters)" }
    "admin.username_too_short" = @{ zh = "管理员用户名至少需要 3 个字符（MinIO 要求）。当前长度: {0}"; en = "Admin username must be at least 3 characters (MinIO requirement). Current length: {0}" }
    "admin.minio_username_too_short" = @{ zh = "AGENTTEAMS_MINIO_USER 至少需要 3 个字符。当前长度: {0}"; en = "AGENTTEAMS_MINIO_USER must be at least 3 characters. Current length: {0}" }
    "admin.password_prompt" = @{ zh = "管理员密码（留空自动生成，最少 8 位）"; en = "Admin Password (leave empty to auto-generate, min 8 chars)" }
    "admin.password_generated" = @{ zh = "  已自动生成管理员密码"; en = "  Auto-generated admin password" }
    "admin.password_too_short" = @{ zh = "管理员密码至少需要 8 个字符（MinIO 要求）。当前长度: {0}"; en = "Admin password must be at least 8 characters (MinIO requirement). Current length: {0}" }

    # --- Port Configuration ---
    "port.title" = @{ zh = "--- 端口配置（按回车使用默认值）---"; en = "--- Port Configuration (press Enter for defaults) ---" }
    "port.gateway_prompt" = @{ zh = "网关主机端口（容器内 8080）"; en = "Host port for gateway (8080 inside container)" }
    "port.console_prompt" = @{ zh = "Higress 控制台主机端口（容器内 8001）"; en = "Host port for Higress console (8001 inside container)" }
    "port.element_prompt" = @{ zh = "Element Web 直接访问主机端口（容器内 8088）"; en = "Host port for Element Web direct access (8088 inside container)" }
    "port.manager_console_prompt" = @{ zh = "Manager 控制台主机端口（容器内 18888）"; en = "Host port for Manager console (18888 inside container)" }
    "port.local_only.title" = @{ zh = "--- 网络访问模式 ---"; en = "--- Network Access Mode ---" }
    "port.local_only.hint_yes" = @{ zh = "  仅本机使用，无需开放外部端口（推荐）"; en = "  Local use only, no external port exposure (recommended)" }
    "port.local_only.hint_no" = @{ zh = "  允许外部访问（局域网 / 公网）"; en = "  Allow external access (LAN / public network)" }
    "port.local_only.choice" = @{ zh = "请选择 [1/2]"; en = "Enter choice [1/2]" }
    "port.local_only.selected_local" = @{ zh = "端口已绑定到 127.0.0.1（仅本机访问）"; en = "Ports bound to 127.0.0.1 (localhost only)" }
    "port.local_only.selected_external" = @{ zh = "端口已绑定到所有网络接口（0.0.0.0）"; en = "Ports bound to all interfaces (0.0.0.0)" }
    "port.local_only.https_hint" = @{ zh = "警告: 建议在 Higress 控制台配置 TLS 证书并启用 HTTPS，避免明文传输。"; en = "WARNING: It is recommended to configure TLS certificates and enable HTTPS in the Higress Console to avoid plaintext transmission." }
    "port.local_only.https_docs" = @{ zh = ""; en = "" }

    # --- Domain Configuration ---
    "domain.title" = @{ zh = "--- 域名配置（按回车使用默认值）---"; en = "--- Domain Configuration (press Enter for defaults) ---" }
    "domain.hint" = @{ zh = "提示: 自定义域名前必须事先做好 DNS 解析。单机 ECS 部署时无需修改 aigw、fs 等域名；Element Web 和 Matrix Server 也可通过 IP 直接访问。"; en = "Hint: Configure DNS resolution before customizing domains. For single ECS deployment, no need to change aigw, fs, etc.; Element Web and Matrix Server can also be accessed directly via IP." }
    "domain.matrix_prompt" = @{ zh = "Matrix 域名"; en = "Matrix Domain" }
    "domain.element_prompt" = @{ zh = "Element Web 域名"; en = "Element Web Domain" }
    "domain.gateway_prompt" = @{ zh = "AI 网关域名"; en = "AI Gateway Domain" }
    "domain.fs_prompt" = @{ zh = "文件系统域名"; en = "File System Domain" }
    "domain.console_prompt" = @{ zh = "Manager 控制台域名"; en = "Manager Console Domain" }

    # --- GitHub Integration ---
    "github.title" = @{ zh = "--- GitHub 集成（可选，按回车跳过）---"; en = "--- GitHub Integration (optional, press Enter to skip) ---" }
    "github.token_prompt" = @{ zh = "GitHub 个人访问令牌（可选）"; en = "GitHub Personal Access Token (optional)" }

    # --- Skills Registry ---
    "skills.title" = @{ zh = "--- Skills 注册中心（可选，按回车使用默认 nacos://market.agentteams.io:80/public）---"; en = "--- Skills Registry (optional, press Enter for default nacos://market.agentteams.io:80/public) ---" }
    "skills.url_prompt" = @{ zh = "Skills 注册中心 URL（留空使用默认 nacos://market.agentteams.io:80/public）"; en = "Skills Registry URL (leave empty for default nacos://market.agentteams.io:80/public)" }

    # --- Data Persistence ---
    "data.title" = @{ zh = "--- 数据持久化 ---"; en = "--- Data Persistence ---" }
    "data.volume_prompt" = @{ zh = "Docker 卷名称 [$($script:DEFAULT_DATA_VOLUME)]"; en = "Docker volume name for persistent data [$($script:DEFAULT_DATA_VOLUME)]" }
    "data.volume_using" = @{ zh = "  使用 Docker 卷: {0}"; en = "  Using Docker volume: {0}" }

    # --- Manager Workspace ---
    "workspace.title" = @{ zh = "--- Manager 工作空间 ---"; en = "--- Manager Workspace ---" }
    "workspace.dir_prompt" = @{ zh = "Manager 工作空间目录 [{0}]"; en = "Manager workspace directory [{0}]" }
    "workspace.dir_label" = @{ zh = "  Manager 工作空间: {0}"; en = "  Manager workspace: {0}" }

    # --- Host directory sharing ---
    "host_share.prompt" = @{ zh = "与 Agent 共享的主机目录（默认: {0}）"; en = "Host directory to share with agents (default: {0})" }
    "host_share.sharing" = @{ zh = "共享主机目录: {0} -> 容器内 /host-share"; en = "Sharing host directory: {0} -> /host-share in container" }
    "host_share.not_exist" = @{ zh = "警告: 主机目录 {0} 不存在，跳过验证继续使用"; en = "WARNING: Host directory {0} does not exist, using without validation" }

    # --- Default worker runtime ---
    "worker_runtime.title" = @{ zh = "--- 默认 Worker 运行时 ---"; en = "--- Default Worker Runtime ---" }
    "worker_runtime.openclaw" = @{ zh = "OpenClaw（兼容，不推荐）"; en = "OpenClaw (legacy, not recommended)" }
    "worker_runtime.qwenpaw" = @{ zh = "QwenPaw"; en = "QwenPaw" }
    "worker_runtime.codex" = @{ zh = "Codex（默认）"; en = "Codex (default)" }
    "worker_runtime.copaw" = @{ zh = "CoPaw（旧版本，建议升级为 QwenPaw）"; en = "CoPaw (legacy; upgrade to QwenPaw recommended)" }
    "worker_runtime.hermes" = @{ zh = "Hermes"; en = "Hermes" }
    "worker_runtime.deepseek_harness" = @{ zh = "DeepSeek Harness（实验性）"; en = "DeepSeek Harness (experimental)" }
    "worker_runtime.deepseek_unavailable" = @{ zh = "当前 Controller 版本不支持 DeepSeek Harness；请使用 v1.2.4+，或同时覆盖兼容的 Worker 与 embedded Controller 镜像"; en = "The selected Controller version does not support DeepSeek Harness; use v1.2.4+, or override both the Worker and compatible embedded Controller image" }
    "worker_runtime.choice" = @{ zh = "请选择 [1/2/4/5，默认 5]"; en = "Enter choice [1/2/4/5, default 5]" }
    "worker_runtime.choice_dsh" = @{ zh = "请选择 [1/2/3/4/5，默认 5]"; en = "Enter choice [1/2/3/4/5, default 5]" }
    "worker_runtime.selected" = @{ zh = "默认 Worker 运行时: {0}"; en = "Default Worker runtime: {0}" }
    "worker_runtime.title_short" = @{ zh = "默认 Worker 运行时"; en = "Default Worker Runtime" }

    # --- Manager runtime ---
    "manager_runtime.title" = @{ zh = "--- Manager 运行时 ---"; en = "--- Manager Runtime ---" }
    "manager_runtime.openclaw" = @{ zh = "OpenClaw（兼容，不推荐）"; en = "OpenClaw (legacy, not recommended)" }
    "manager_runtime.qwenpaw" = @{ zh = "QwenPaw（推荐）"; en = "QwenPaw (recommended)" }
    "manager_runtime.copaw" = @{ zh = "CoPaw（旧版本，建议升级为 QwenPaw）"; en = "CoPaw (legacy; upgrade to QwenPaw recommended)" }
    "manager_runtime.hermes" = @{ zh = "Hermes"; en = "Hermes" }
    "manager_runtime.deepseek_harness" = @{ zh = "DeepSeek Harness（实验性）"; en = "DeepSeek Harness (experimental)" }
    "manager_runtime.codex" = @{ zh = "Codex（需新版镜像与 Responses API）"; en = "Codex (updated images and Responses API required)" }
    "manager_runtime.choice" = @{ zh = "请选择 [1/2/3/4/5]"; en = "Enter choice [1/2/3/4/5]" }
    "manager_runtime.codex_images_required" = @{ zh = "Codex Manager 需要显式覆盖支持它的 Manager 与 embedded Controller 镜像；v1.2.7 Codex 镜像仅支持 Worker/Leader。"; en = "Codex Manager requires explicit compatible Manager and embedded Controller image overrides; the v1.2.7 Codex image supports Worker/Leader only." }
    "manager_runtime.e2ee_unsupported" = @{ zh = "DeepSeek Harness 与 Codex Manager 不支持 Matrix E2EE，请设置 AGENTTEAMS_MATRIX_E2EE=0。"; en = "DeepSeek Harness and Codex Managers do not support Matrix E2EE; set AGENTTEAMS_MATRIX_E2EE=0." }
    "manager_runtime.selected" = @{ zh = "Manager 运行时: {0}"; en = "Manager runtime: {0}" }
    "manager_runtime.title_short" = @{ zh = "Manager 运行时"; en = "Manager Runtime" }

    # --- Matrix E2EE ---
    "matrix_e2ee.title" = @{ zh = "--- Matrix 端到端加密（E2EE）---"; en = "--- Matrix End-to-End Encryption (E2EE) ---" }
    "matrix_e2ee.desc" = @{
        zh = "E2EE 会对 Manager 与 Worker 之间的 Matrix 消息进行端到端加密。`n  启用后，即使 Matrix 服务器被入侵，消息内容也无法被窃取。`n  但 E2EE 会增加首次握手耗时，且要求所有 Agent 都支持 matrix-sdk-crypto。`n  如果不确定，建议保持禁用。`n  ⚠ 注意：禁用 E2EE 后，请勿在 Element 上创建默认启用加密的 Private 房间，`n  否则 Agent 将无法读取该房间中的加密消息。请改用 Public 房间或关闭房间加密。"
        en = "E2EE encrypts Matrix messages between Manager and Workers end-to-end.`n  When enabled, message content stays private even if the Matrix server is compromised.`n  However, E2EE adds overhead to the initial handshake and requires all Agents`n  to support matrix-sdk-crypto. If unsure, keep it disabled.`n  ⚠ Note: When E2EE is disabled, do NOT create Private rooms in Element (which`n  enable encryption by default) — Agents cannot read encrypted messages without`n  E2EE support. Use Public rooms or turn off room encryption instead."
    }
    "matrix_e2ee.enable" = @{ zh = "启用 E2EE"; en = "Enable E2EE" }
    "matrix_e2ee.disable" = @{ zh = "禁用 E2EE（推荐）"; en = "Disable E2EE (recommended)" }
    "matrix_e2ee.choice" = @{ zh = "请选择 [1/2]"; en = "Enter choice [1/2]" }
    "matrix_e2ee.selected_enabled" = @{ zh = "Matrix E2EE: 已启用"; en = "Matrix E2EE: enabled" }
    "matrix_e2ee.selected_disabled" = @{ zh = "Matrix E2EE: 已禁用（默认）"; en = "Matrix E2EE: disabled (default)" }
    "matrix_e2ee.title_short" = @{ zh = "Matrix E2EE"; en = "Matrix E2EE" }
    "matrix_e2ee.val_enabled" = @{ zh = "已启用"; en = "enabled" }
    "matrix_e2ee.val_disabled" = @{ zh = "已禁用"; en = "disabled" }

    # --- Docker API proxy ---
    "docker_proxy.title" = @{ zh = "--- Docker API 安全代理 ---"; en = "--- Docker API Security Proxy ---" }
    "docker_proxy.desc" = @{ zh = "Docker API 代理可防止 AI Agent 通过 Docker API 越狱访问宿主机。`n  启用后，Manager 不再直接持有 Docker socket，所有容器操作经过安全校验。"; en = "Docker API proxy prevents AI Agents from escaping via Docker API to access the host.`n  When enabled, Manager no longer has direct Docker socket access; all container operations go through security validation." }
    "docker_proxy.enable" = @{ zh = "启用（推荐）"; en = "Enable (recommended)" }
    "docker_proxy.disable" = @{ zh = "禁用（直接挂载 Docker socket）"; en = "Disable (mount Docker socket directly)" }
    "docker_proxy.choice" = @{ zh = "请选择 [1/2]"; en = "Enter choice [1/2]" }
    "docker_proxy.selected_enabled" = @{ zh = "Docker API 代理: 已启用"; en = "Docker API proxy: enabled" }
    "docker_proxy.selected_disabled" = @{ zh = "Docker API 代理: 已禁用"; en = "Docker API proxy: disabled" }
    "docker_proxy.title_short" = @{ zh = "Docker API 代理"; en = "Docker API Proxy" }
    "docker_proxy.val_enabled" = @{ zh = "已启用"; en = "enabled" }
    "docker_proxy.val_disabled" = @{ zh = "已禁用"; en = "disabled" }
    "docker_proxy.registries_desc" = @{ zh = "默认放行的镜像来源：本地镜像、localhost、Higress 仓库（所有 region）。`n  如需放行其他镜像仓库，请输入逗号分隔的地址前缀。`n  示例: ghcr.io/myorg,registry.example.com/team"; en = "Default allowed image sources: local images, localhost, Higress registries (all regions).`n  To allow additional image sources, enter comma-separated address prefixes.`n  Example: ghcr.io/myorg,registry.example.com/team" }
    "docker_proxy.registries_prompt" = @{ zh = "额外放行的镜像来源（按回车跳过）"; en = "Additional allowed image sources (press Enter to skip)" }
    "docker_proxy.registries_label" = @{ zh = "额外放行的镜像来源"; en = "Additional allowed image sources" }

    # --- Worker idle timeout ---
    "idle_timeout.prompt" = @{ zh = "Worker 空闲自动停止超时（分钟）[720]"; en = "Worker idle auto-stop timeout in minutes [720]" }
    "idle_timeout.selected" = @{ zh = "Worker 空闲超时: {0} 分钟"; en = "Worker idle timeout: {0} minutes" }
    "idle_timeout.label" = @{ zh = "Worker 空闲超时（分钟）"; en = "Worker idle timeout (min)" }

    # --- Secrets and config ---
    "install.generating_secrets" = @{ zh = "正在生成密钥..."; en = "Generating secrets..." }
    "install.config_saved" = @{ zh = "配置已保存到 {0}"; en = "Configuration saved to {0}" }

    # --- Container runtime socket ---
    "install.socket_detected" = @{ zh = "容器运行时 socket: {0}（已启用直接创建 Worker）"; en = "Container runtime socket: {0} (direct Worker creation enabled)" }
    "install.socket_not_found" = @{ zh = "未找到容器运行时 socket（Manager 无法直接创建 Worker 容器，需要你手动执行 docker 命令创建）"; en = "No container runtime socket found (Manager cannot create Worker containers directly, you will need to create them manually using docker commands)" }
    "install.socket_confirm.title" = @{ zh = "警告: 未检测到容器运行时 Socket"; en = "WARNING: Container Runtime Socket Not Detected" }
    "install.socket_confirm.message" = @{ zh = "未找到 Docker/Podman socket，Manager 将无法自动创建 Worker 容器。`n你需要手动执行 docker run 命令来创建 Worker。`n`n是否继续安装？"; en = "Docker/Podman socket not found. Manager will not be able to create Worker containers automatically.`nYou will need to manually run docker commands to create Workers.`n`nContinue installation?" }
    "install.socket_confirm.prompt" = @{ zh = "继续安装? [y/N]: "; en = "Continue? [y/N]: " }
    "install.socket_confirm.cancelled" = @{ zh = "安装已取消。如需启用 Worker 自动创建，请确保 Docker/Podman 正在运行，然后重新运行安装脚本。"; en = "Installation cancelled. To enable automatic Worker creation, ensure Docker/Podman is running and re-run the installer." }

    # --- Container management ---
    "install.removing_existing" = @{ zh = "正在移除现有 $($script:MANAGER_CONTAINER) 容器..."; en = "Removing existing $($script:MANAGER_CONTAINER) container..." }

    # --- YOLO mode ---
    "install.yolo" = @{ zh = "YOLO 模式已启用（自主决策，无交互提示）"; en = "YOLO mode enabled (autonomous decisions, no interactive prompts)" }

    # --- Image pulling ---
    "install.image.dashboard_exists" = @{ zh = "Dashboard 镜像已就绪"; en = "Dashboard image is ready" }
    "install.image.pulling_dashboard" = @{ zh = "准备 Dashboard 镜像..."; en = "Preparing Dashboard image..." }
    "install.image.exists" = @{ zh = "Manager 镜像已就绪"; en = "Manager image is ready" }
    "install.image.pulling_manager" = @{ zh = "准备 Manager 镜像..."; en = "Preparing Manager image..." }
    "install.image.embedded_exists" = @{ zh = "基础服务镜像已就绪"; en = "Core services image is ready" }
    "install.image.pulling_embedded" = @{ zh = "准备基础服务镜像..."; en = "Preparing core services image..." }
    "install.image.worker_exists" = @{ zh = "Worker 镜像已存在: {0}"; en = "Worker image already exists locally: {0}" }
    "install.image.pulling_worker" = @{ zh = "正在拉取 Worker 镜像: {0}"; en = "Pulling Worker image: {0}" }

    # --- Starting container ---
    "install.starting_manager" = @{ zh = "正在启动 Manager 容器..."; en = "Starting Manager container..." }

    # --- Wait for Manager ready ---
    "install.wait_ready" = @{ zh = "等待 Manager Agent 就绪（超时: {0}s）..."; en = "Waiting for Manager agent to be ready (timeout: {0}s)..." }
    "install.wait_ready.ok" = @{ zh = "Manager Agent 已就绪！"; en = "Manager agent is ready!" }
    "install.wait_ready.waiting" = @{ zh = "等待中... ({0}s/{1}s)"; en = "Waiting... ({0}s/{1}s)" }
    "install.wait_ready.timeout" = @{ zh = "Manager Agent 在 {0}s 内未就绪。请检查: docker logs {1}"; en = "Manager agent did not become ready within {0}s. Check: docker logs {1}" }

    # --- Wait for Matrix ready ---
    "install.wait_matrix" = @{ zh = "等待 Matrix 服务就绪（超时: {0}s）..."; en = "Waiting for Matrix server to be ready (timeout: {0}s)..." }
    "install.wait_matrix.ok" = @{ zh = "Matrix 服务已就绪！"; en = "Matrix server is ready!" }
    "install.wait_matrix.waiting" = @{ zh = "等待 Matrix 中... ({0}s/{1}s)"; en = "Waiting for Matrix... ({0}s/{1}s)" }
    "install.wait_matrix.timeout" = @{ zh = "Matrix 服务在 {0}s 内未就绪。请检查: docker logs {1}"; en = "Matrix server did not become ready within {0}s. Check: docker logs {1}" }

    # --- OpenAI-compatible connectivity test ---
    "llm.openai.test.testing" = @{ zh = "正在测试 API 联通性..."; en = "Testing API connectivity..." }
    "llm.openai.test.ok" = @{ zh = "API 联通性测试通过"; en = "API connectivity test passed" }
    "llm.openai.test.fail" = @{ zh = "API 联通性测试失败（HTTP {0}）。响应内容:`n{1}`n请根据以上错误信息联系您的模型服务商解决。"; en = "API connectivity test failed (HTTP {0}). Response body:`n{1}`nPlease contact your model provider to resolve the issue." }
    "llm.openai.test.fail.tokenplan" = @{ zh = "提示: 请确认 API Key 有效且已开通通义 Token 套餐。文档: https://help.aliyun.com/zh/model-studio/token-plan-quickstart"; en = "Hint: Verify your Token Plan API key and compatible-mode access. Docs: https://help.aliyun.com/zh/model-studio/token-plan-quickstart" }
    "llm.openai.test.fail.codingplan" = @{ zh = "提示: 请确认 API Key 有效且已开通通义 Token 套餐。文档: https://help.aliyun.com/zh/model-studio/token-plan-quickstart"; en = "Hint: Verify your DASHSCOPE_API_KEY for Qwen Cloud. API keys: https://home.qwencloud.com/api-keys  Docs: https://docs.qwencloud.com/" }
    "llm.openai.test.fail.codingplan_legacy" = @{ zh = "提示: 请确认 API Key 有效且 Coding 套餐接口可用。文档: https://help.aliyun.com/zh/model-studio/get-api-key"; en = "Hint: Verify your DashScope API key and Coding Plan access. Docs: https://help.aliyun.com/zh/model-studio/get-api-key" }
    "llm.openai.test.confirm" = @{ zh = "是否仍要继续安装？[y/N/b]"; en = "Continue with installation anyway? [y/N/b]" }
    "llm.openai.test.aborted" = @{ zh = "安装已中止。"; en = "Installation aborted." }
    "llm.embedding.title" = @{ zh = "📦 记忆搜索配置"; en = "📦 Memory Search Configuration" }
    "llm.embedding.hint" = @{ zh = "  Embedding 模型可提升记忆搜索质量（语义匹配）。不启用也可正常使用记忆功能（关键词匹配）。"; en = "  Embedding model improves memory search quality (semantic matching). Memory still works without it (keyword matching)." }
    "llm.embedding.option.default" = @{ zh = "  1) text-embedding-v4（推荐）"; en = "  1) text-embedding-v4 (Recommended)" }
    "llm.embedding.option.custom" = @{ zh = "  2) 自定义 Embedding 模型"; en = "  2) Custom embedding model" }
    "llm.embedding.option.disable" = @{ zh = "  3) 不启用"; en = "  3) Do not enable" }
    "llm.embedding.select" = @{ zh = "选择"; en = "Select" }
    "llm.embedding.custom_prompt" = @{ zh = "  Embedding 模型名称"; en = "  Embedding model name" }
    "llm.embedding.test.testing" = @{ zh = "正在测试 Embedding API 联通性..."; en = "Testing Embedding API connectivity..." }
    "llm.embedding.test.ok" = @{ zh = "✅ Embedding API 联通性测试通过"; en = "✅ Embedding API connectivity test passed" }
    "llm.embedding.test.fail" = @{ zh = "⚠️  Embedding API 测试失败（HTTP {0}）。响应: {1}"; en = "⚠️  Embedding API test failed (HTTP {0}). Response: {1}" }
    "llm.embedding.auto_disabled" = @{ zh = "⚠️  Embedding 已自动禁用，记忆搜索将使用关键词匹配。您可以稍后在 agentteams-manager.env 中设置 AGENTTEAMS_EMBEDDING_MODEL 启用。"; en = "⚠️  Embedding auto-disabled. Memory search will use keyword matching. You can enable it later in agentteams-manager.env by setting AGENTTEAMS_EMBEDDING_MODEL." }
    "llm.embedding.disabled" = @{ zh = "ℹ️  Embedding 已禁用，记忆搜索将使用关键词匹配。"; en = "ℹ️  Embedding disabled. Memory search will use keyword matching." }
    "nav.back_hint" = @{ zh = "（输入 b 返回上一步）"; en = "(enter b to go back)" }
    # --- OpenAI-compatible provider creation ---
    "install.openai_compat.missing" = @{ zh = "警告: OpenAI Base URL 或 API Key 未设置，跳过提供商创建"; en = "WARNING: OpenAI Base URL or API Key not set, skipping provider creation" }
    "install.openai_compat.creating" = @{ zh = "正在创建 OpenAI 兼容提供商..."; en = "Creating OpenAI-compatible provider..." }
    "install.openai_compat.domain" = @{ zh = "  域名: {0}"; en = "  Domain: {0}" }
    "install.openai_compat.port" = @{ zh = "  端口: {0}"; en = "  Port: {0}" }
    "install.openai_compat.protocol" = @{ zh = "  协议: {0}"; en = "  Protocol: {0}" }
    "install.openai_compat.service_fail" = @{ zh = "警告: 创建 DNS 服务源失败（可能已存在）"; en = "WARNING: Failed to create DNS service source (may already exist)" }
    "install.openai_compat.provider_fail" = @{ zh = "警告: 创建 AI 提供商失败（可能已存在）"; en = "WARNING: Failed to create AI provider (may already exist)" }
    "install.openai_compat.success" = @{ zh = "OpenAI 兼容提供商创建成功"; en = "OpenAI-compatible provider created successfully" }

    # --- Welcome message ---
    "install.model_unavailable" = @{ zh = "警告：模型连接暂不可用，继续启动服务。启动后可在 Dashboard 中修正模型配置。"; en = "WARNING: Model connection is unavailable. Continuing startup; update model settings in Dashboard afterward." }
    "install.welcome_msg.background" = @{ zh = "欢迎消息将在模型连接可用后由 Manager 后台发送，不影响服务启动。"; en = "The Manager will send its welcome message in the background when the model is available; service startup does not wait for it." }
    "install.welcome_msg.soul_configured" = @{ zh = "Soul 已配置（找到 soul-configured 标记），跳过 onboarding 消息"; en = "Soul already configured (soul-configured marker found), skipping onboarding message" }
    "install.welcome_msg.logging_in" = @{ zh = "正在以 {0} 身份登录以发送欢迎消息..."; en = "Logging in as {0} to send welcome message..." }
    "install.welcome_msg.login_failed" = @{ zh = "警告: 以 {0} 身份登录失败，跳过欢迎消息"; en = "WARNING: Failed to login as {0}, skipping welcome message" }
    "install.welcome_msg.finding_room" = @{ zh = "正在查找与 Manager 的 DM 房间..."; en = "Finding DM room with Manager..." }
    "install.welcome_msg.creating_room" = @{ zh = "正在创建与 Manager 的 DM 房间..."; en = "Creating DM room with Manager..." }
    "install.welcome_msg.no_room" = @{ zh = "警告: 无法找到或创建与 Manager 的 DM 房间"; en = "WARNING: Could not find or create DM room with Manager" }
    "install.welcome_msg.waiting_join" = @{ zh = "等待 Manager 加入房间..."; en = "Waiting for Manager to join the room..." }
    "install.welcome_msg.sending" = @{ zh = "正在向 Manager 发送欢迎消息..."; en = "Sending welcome message to Manager..." }
    "install.welcome_msg.send_failed" = @{ zh = "警告: 发送欢迎消息失败"; en = "WARNING: Failed to send welcome message" }
    "install.welcome_msg.sent" = @{ zh = "欢迎消息已发送给 Manager"; en = "Welcome message sent to Manager" }
    "install.welcome_msg.waiting" = @{ zh = "等待 Manager 发送欢迎消息（Higress 路由授权 + LLM 探活，约 45-90s）..."; en = "Waiting for Manager to send the welcome message (Higress route auth + LLM probe, ~45-90s)..." }
    "install.welcome_msg.confirmed" = @{ zh = "Manager 已确认发送欢迎消息（status.welcomeSent=true，用时 {0}s）"; en = "Manager confirmed welcome message sent (status.welcomeSent=true, {0}s elapsed)" }
    "install.welcome_msg.timeout" = @{ zh = "警告: 在 {0}s 内未观察到 Manager 发送欢迎消息（status.welcomeSent=true）。安装仍然成功，所有服务已就绪——可继续按下方提示登录 Element Web。"; en = "WARNING: Did not observe the Manager sending its welcome message (status.welcomeSent=true) within {0}s. Installation is still successful, all services are up — continue with the Element Web instructions below." }
    "install.welcome_msg.timeout_hint" = @{ zh = "手动触发 onboarding: 登录 Element Web → 打开与 Manager 的 DM 房间 → 发送任意一句话（例如 `"hi`"），Manager 会接管对话并开始引导。"; en = "Manual onboarding: log in to Element Web -> open the DM with the Manager -> send any message (e.g. `"hi`") and the Manager will take over and start the guided setup." }
    "install.welcome_msg.timeout_inspect" = @{ zh = "排查命令: docker exec $($script:CONTROLLER_CONTAINER) agt get managers default"; en = "Inspect status: docker exec $($script:CONTROLLER_CONTAINER) agt get managers default" }
    "install.welcome_msg.poll_unavailable" = @{ zh = "提示: $($script:MANAGER_CONTAINER) 内未找到 AgentTeams CLI，跳过 welcome 等待（旧镜像？）"; en = "Note: AgentTeams CLI not found inside $($script:MANAGER_CONTAINER); skipping welcome wait (old image?)" }

    # --- Final output panel ---
    "success.title" = @{ zh = "=== AgentTeams 已启动 ==="; en = "=== AgentTeams Started ===" }
    "success.domains_configured" = @{ zh = "以下域名已配置解析到 127.0.0.1:"; en = "The following domains are configured to resolve to 127.0.0.1:" }
    "success.open_url" = @{ zh = "  在浏览器中打开以下 URL 开始使用:                           "; en = "  Open the following URL in your browser to start:                           " }
    "success.login_with" = @{ zh = "  登录信息:"; en = "  Login with:" }
    "success.username" = @{ zh = "    用户名: {0}"; en = "    Username: {0}" }
    "success.password" = @{ zh = "    密码: {0}"; en = "    Password: {0}" }
    "success.after_login" = @{ zh = "  登录后，开始与 Manager 聊天！"; en = "  After login, start chatting with the Manager!" }
    "success.tell_it" = @{ zh = "    告诉它: `"创建一个名为 alice 的前端开发 Worker`""; en = "    Tell it: `"Create a Worker named alice for frontend dev`"" }
    "success.manager_auto" = @{ zh = "    Manager 会自动处理一切。"; en = "    The Manager will handle everything automatically." }
    "success.mobile_title" = @{ zh = "  移动端访问（FluffyChat / Element Mobile）:"; en = "  Mobile access (FluffyChat / Element Mobile):" }
    "success.mobile_step1" = @{ zh = "    1. 在手机上下载 FluffyChat 或 Element"; en = "    1. Download FluffyChat or Element on your phone" }
    "success.mobile_step2" = @{ zh = "    2. 设置 homeserver 为: {0}"; en = "    2. Set homeserver to: {0}" }
    "success.mobile_step2_noip" = @{ zh = "    2. 设置 homeserver 为: http://<本机局域网IP>:{0}"; en = "    2. Set homeserver to: http://<this-machine-LAN-IP>:{0}" }
    "success.mobile_noip_hint" = @{ zh = "       （无法自动检测局域网 IP — 请使用 ifconfig / ip addr 查看）"; en = "       (Could not detect LAN IP automatically — check with: ifconfig / ip addr)" }
    "success.mobile_step3" = @{ zh = "    3. 登录信息:"; en = "    3. Login with:" }
    "success.mobile_username" = @{ zh = "         用户名: {0}"; en = "         Username: {0}" }
    "success.mobile_password" = @{ zh = "         密码: {0}"; en = "         Password: {0}" }

    # --- Other consoles and tips ---
    "success.other_consoles" = @{ zh = "--- 其他控制台 ---"; en = "--- Other Consoles ---" }
    "success.higress_console" = @{ zh = "  Higress 控制台: http://localhost:{0}（用户名: {1} / 密码: {2}）"; en = "  Higress Console: http://localhost:{0} (Username: {1} / Password: {2})" }
    "success.manager_console" = @{ zh = "  Manager 控制台（本地）: http://localhost:{0}（无需登录）"; en = "  Manager Console (local): http://localhost:{0} (no login required)" }
    "success.manager_console_gateway" = @{ zh = "  Manager 控制台（网关）: http://console-local.agentteams.io（用户名: {0} / 密码: {1}）"; en = "  Manager Console (gateway): http://console-local.agentteams.io (Username: {0} / Password: {1})" }
    "success.switch_llm.title" = @{ zh = "--- 切换 LLM 提供商 ---"; en = "--- Switch LLM Providers ---" }
    "success.switch_llm.hint" = @{ zh = "  您可以通过 Higress 控制台切换到其他 LLM 提供商（OpenAI、Anthropic 等）。"; en = "  You can switch to other LLM providers (OpenAI, Anthropic, etc.) via Higress Console." }
    "success.switch_llm.docs" = @{ zh = "  详细说明请参阅:"; en = "  For detailed instructions, see:" }
    "success.switch_llm.url" = @{ zh = "  https://higress.ai/en/docs/ai/scene-guide/multi-proxy#console-configuration"; en = "  https://higress.ai/en/docs/ai/scene-guide/multi-proxy#console-configuration" }
    "success.tip" = @{ zh = "提示: 您也可以在聊天中让 Manager 为您配置 LLM 提供商。"; en = "Tip: You can also ask the Manager to configure LLM providers for you in the chat." }
    "success.config_file" = @{ zh = "配置文件: {0}"; en = "Configuration file: {0}" }
    "success.data_volume" = @{ zh = "数据卷:        {0}"; en = "Data volume:        {0}" }
    "success.workspace" = @{ zh = "Manager 工作空间:  {0}"; en = "Manager workspace:  {0}" }

    # --- Worker installation ---
    "worker.resetting" = @{ zh = "正在重置 Worker: {0}..."; en = "Resetting Worker: {0}..." }
    "worker.exists" = @{ zh = "容器 '{0}' 已存在。使用 --reset 重新创建。"; en = "Container '{0}' already exists. Use --reset to recreate." }
    "worker.starting" = @{ zh = "正在启动 Worker: {0}..."; en = "Starting Worker: {0}..." }
    "worker.skills_url" = @{ zh = "  Skills API URL: {0}"; en = "  Skills API URL: {0}" }
    "worker.started" = @{ zh = "=== Worker {0} 已启动！==="; en = "=== Worker {0} Started! ===" }
    "worker.container" = @{ zh = "容器: {0}"; en = "Container: {0}" }
    "worker.view_logs" = @{ zh = "查看日志: docker logs -f {0}"; en = "View logs: docker logs -f {0}" }

    # --- Prompt function messages ---
    "prompt.preset" = @{ zh = "  {0} = （已通过环境变量预设）"; en = "  {0} = (pre-set via env)" }
    "prompt.upgrade_keep" = @{ zh = "  {0} = {1}（当前值，回车保留 / 输入新值覆盖）"; en = "  {0} = {1} (current value, press Enter to keep / type new value to change)" }
    "prompt.upgrade_empty" = @{ zh = "  {0} = （未设置，回车跳过 / 输入新值设置）"; en = "  {0} = (not set, press Enter to skip / type new value to set)" }
    "prompt.default" = @{ zh = "  {0} = {1}（默认）"; en = "  {0} = {1} (default)" }
    "prompt.required" = @{ zh = "{0} 是必需的（在非交互模式下通过环境变量设置）"; en = "{0} is required (set via environment variable in non-interactive mode)" }
    "prompt.required_empty" = @{ zh = "{0} 是必需的"; en = "{0} is required" }

    # --- Language switch prompt (bilingual by design) ---
    "lang.detected.zh" = @{ zh = "检测到语言 / Detected language: 中文"; en = "检测到语言 / Detected language: 中文" }
    "lang.detected.en" = @{ zh = "检测到语言 / Detected language: English"; en = "检测到语言 / Detected language: English" }
    "lang.switch_title" = @{ zh = "切换语言 / Switch language:"; en = "切换语言 / Switch language:" }
    "lang.option_zh" = @{ zh = "  1) 中文"; en = "  1) 中文" }
    "lang.option_en" = @{ zh = "  2) English"; en = "  2) English" }
    "lang.prompt" = @{ zh = "请选择 / Enter choice"; en = "请选择 / Enter choice" }

    # --- Error messages ---
    "error.name_required" = @{ zh = "--name 是必需的"; en = "--name is required" }
    "error.fs_required" = @{ zh = "--fs 是必需的"; en = "--fs is required" }
    "error.fs_key_required" = @{ zh = "--fs-key 是必需的"; en = "--fs-key is required" }
    "error.fs_secret_required" = @{ zh = "--fs-secret 是必需的"; en = "--fs-secret is required" }
    "error.unknown_option" = @{ zh = "未知选项: {0}"; en = "Unknown option: {0}" }
    "error.docker_not_running" = @{ zh = "Docker 未运行。请先启动 Docker Desktop 或 Podman Desktop。"; en = "Docker is not running. Please start Docker Desktop or Podman Desktop first." }
    "error.docker_not_found" = @{ zh = "未找到 docker 或 podman 命令。请先安装 Docker Desktop 或 Podman Desktop：`n  Docker Desktop: https://www.docker.com/products/docker-desktop/`n  Podman Desktop: https://podman-desktop.io/"; en = "docker or podman command not found. Please install Docker Desktop or Podman Desktop first:`n  Docker Desktop: https://www.docker.com/products/docker-desktop/`n  Podman Desktop: https://podman-desktop.io/" }

    # --- Uninstall messages ---
    "uninstall.title" = @{ zh = "正在卸载 AgentTeams..."; en = "Uninstalling AgentTeams..." }
    "uninstall.stopping_manager" = @{ zh = "正在停止并移除 agentteams-manager..."; en = "Stopping and removing agentteams-manager..." }
    "uninstall.stopping_workers" = @{ zh = "正在停止并移除 worker 容器..."; en = "Stopping and removing worker containers..." }
    "uninstall.removed" = @{ zh = "  已移除: {0}"; en = "  Removed: {0}" }
    "uninstall.removing_volume" = @{ zh = "正在移除 Docker 卷: $($script:DEFAULT_DATA_VOLUME)"; en = "Removing Docker volume: $($script:DEFAULT_DATA_VOLUME)" }
    "uninstall.removing_env" = @{ zh = "正在移除 env 文件: {0}"; en = "Removing env file: {0}" }
    "uninstall.removing_proxy" = @{ zh = "正在停止并移除 Docker API 代理容器: $($script:DOCKER_PROXY_CONTAINER)"; en = "Stopping and removing Docker API proxy container: $($script:DOCKER_PROXY_CONTAINER)" }
    "uninstall.stopping_controller" = @{ zh = "正在停止并移除 $($script:CONTROLLER_CONTAINER) (内嵌 Tuwunel/MinIO/Higress)..."; en = "Stopping and removing $($script:CONTROLLER_CONTAINER) (embedded Tuwunel/MinIO/Higress)..." }
    "uninstall.removing_network" = @{ zh = "正在移除 Docker 网络: $($script:DOCKER_NETWORK)"; en = "Removing Docker network: $($script:DOCKER_NETWORK)" }
    "uninstall.removing_workspace" = @{ zh = "正在移除工作空间目录: {0}"; en = "Removing workspace directory: {0}" }
    "uninstall.removing_log" = @{ zh = "正在移除日志文件: {0}"; en = "Removing log file: {0}" }
    "uninstall.done" = @{ zh = "AgentTeams 已卸载。"; en = "AgentTeams has been uninstalled." }
}

# Get-Msg: look up message by key, with -f style argument substitution.
# Falls back to English if the current language translation is missing.
function Get-Msg {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$f
    )
    $lang = $script:AGENTTEAMS_LANGUAGE
    if (-not $lang) { $lang = "en" }
    $entry = $script:Messages[$Key]
    if (-not $entry) { return $Key }
    $text = $entry[$lang]
    if (-not $text) { $text = $entry["en"] }
    if (-not $text) { return $Key }
    if ($null -ne $f -and $f.Count -gt 0) { return ($text -f $f) }
    return $text
}

function Get-LanIP {
    # Detect local LAN IP address on Windows
    try {
        # Get network adapters with IPv4 addresses, prefer connected/active interfaces
        $adapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object {
                $_.IPAddress -notlike "127.*" -and
                $_.PrefixOrigin -ne "WellKnown" -and
                $_.InterfaceAlias -notlike "*Loopback*"
            } |
            Sort-Object {
                # PowerShell 5.1 compatible: use if-else instead of ternary operator
                if ($_.InterfaceAlias -like "*Wi-Fi*" -or $_.InterfaceAlias -like "*Ethernet*") { 0 } else { 1 }
            }

        if ($adapters) {
            return $adapters[0].IPAddress
        }

        # Fallback: use ipconfig
        $ipconfig = ipconfig 2>$null
        $ip = ($ipconfig | Select-String "IPv4 Address.*?: (\d+\.\d+\.\d+\.\d+)" | Select-Object -First 1)
        if ($ip -match "(\d+\.\d+\.\d+\.\d+)") {
            return $Matches[1]
        }
    }
    catch {
        # Ignore errors
    }

    return ""
}

# Known models list — used to detect custom models during install
$script:KnownModels = @(
    "gpt-5.4", "gpt-5.3-codex", "gpt-5-mini", "gpt-5-nano",
    "claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5",
    "qwen3.6-plus", "qwen3.5-plus", "deepseek-chat", "deepseek-reasoner",
    "kimi-k2.5", "glm-5.2", "glm-5", "MiniMax-M2.7", "MiniMax-M2.7-highspeed", "MiniMax-M2.5"
)

function Test-KnownModel {
    param([string]$Model)
    return $script:KnownModels -contains $Model
}

function Request-CustomModelParams {
    param([string]$Model)
    if (Test-KnownModel $Model) {
        $script:config.MODEL_CONTEXT_WINDOW = ""
        $script:config.MODEL_MAX_TOKENS = ""
        $script:config.MODEL_REASONING = ""
        $script:config.MODEL_VISION = ""
        return
    }
    Write-Host ""
    Write-Log (Get-Msg "llm.custom_model.detected" -f $Model)
    Write-Host ""
    $ctxInput = Read-Host "  $(Get-Msg 'llm.custom_model.context_prompt')"
    if ($ctxInput -eq "b") { $script:StepResult = "back"; return }
    $script:config.MODEL_CONTEXT_WINDOW = if ($ctxInput) { $ctxInput } else { "150000" }
    $maxInput = Read-Host "  $(Get-Msg 'llm.custom_model.max_tokens_prompt')"
    if ($maxInput -eq "b") { $script:StepResult = "back"; return }
    $script:config.MODEL_MAX_TOKENS = if ($maxInput) { $maxInput } else { "128000" }
    $reasoningInput = Read-Host "  $(Get-Msg 'llm.custom_model.reasoning_prompt')"
    if ($reasoningInput -eq "b") { $script:StepResult = "back"; return }
    $script:config.MODEL_REASONING = if ($reasoningInput -match "^[nN]") { "false" } else { "true" }
    $visionInput = Read-Host "  $(Get-Msg 'llm.custom_model.vision_prompt')"
    if ($visionInput -eq "b") { $script:StepResult = "back"; return }
    $script:config.MODEL_VISION = if ($visionInput -match "^[yY]") { "true" } else { "false" }
    Write-Log (Get-Msg "llm.custom_model.summary" -f $script:config.MODEL_CONTEXT_WINDOW, $script:config.MODEL_MAX_TOKENS, $script:config.MODEL_REASONING, $script:config.MODEL_VISION)
}

function New-RandomKey {
    # Generate 64 character hex string (32 bytes)
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return [BitConverter]::ToString($bytes).Replace("-", "").ToLower()
}

function ConvertTo-DockerPath {
    param([string]$Path)

    # Convert Windows path to Docker mount format
    $fullPath = (Resolve-Path $Path -ErrorAction SilentlyContinue).Path
    if (-not $fullPath) {
        $fullPath = $Path
    }

    # Convert C:\path to /c/path format for Docker
    if ($fullPath -match "^([A-Za-z]):") {
        $drive = $Matches[1].ToLower()
        $rest = $fullPath.Substring(2).Replace("\", "/")
        return "/$drive$rest"
    }
    return $fullPath.Replace("\", "/")
}

# Resolve the embedded controller image. Embedded mode is the only supported
# architecture since PR #616 (manager image no longer bundles Higress/Tuwunel/MinIO).
# Mirrors install/agentteams-install.sh::resolve_embedded_image — fail fast when the
# embedded image is unavailable rather than silently falling back to the broken
# legacy single-container path.
# Sets $script:EMBEDDED_IMAGE and $script:AGENTTEAMS_USE_EMBEDDED.
function Resolve-EmbeddedImage {
    $script:AGENTTEAMS_USE_EMBEDDED = "1"

    # Explicit override always wins (used by `make install-embedded` for local builds).
    if ($env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE) {
        $script:EMBEDDED_IMAGE = $env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE
        return
    }

    $versioned = "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-embedded:$($script:AGENTTEAMS_VERSION)"
    $latestTag = "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-embedded:latest"

    # Always pull mutable remote tags, including :latest. Docker otherwise reuses an
    # existing local tag and can start an embedded controller from an older release.
    if ($script:AGENTTEAMS_VERSION -ne "latest") {
        Write-Log (Get-Msg "install.image.pulling_embedded" -f $versioned)
        docker pull $versioned *>$null
        if ($LASTEXITCODE -eq 0) {
            $script:EMBEDDED_IMAGE = $versioned
            return
        }
        throw "Pinned embedded image $versioned is unavailable. Refusing fallback to latest."
    }
    Write-Log (Get-Msg "install.image.pulling_embedded" -f $latestTag)
    docker pull $latestTag *>$null
    if ($LASTEXITCODE -eq 0) {
        if ($script:AGENTTEAMS_VERSION -ne "latest") {
            Write-Log "embedded $($script:AGENTTEAMS_VERSION) not found, using latest"
        }
        $script:EMBEDDED_IMAGE = $latestTag
        return
    }

    # Escape hatch for older versions (AGENTTEAMS_VERSION <= v1.0.9) whose manager image
    # still bundled the infrastructure — opt-in only, never silent.
    if ($env:AGENTTEAMS_FORCE_LEGACY -eq "1") {
        Write-Log "WARNING: AGENTTEAMS_FORCE_LEGACY=1 - using legacy all-in-one manager architecture."
        Write-Log "WARNING: This requires AGENTTEAMS_VERSION <= v1.0.9 (older bundled manager image)."
        Write-Log "WARNING: Newer slim manager images will hang on 'Waiting for Higress Gateway'."
        $script:AGENTTEAMS_USE_EMBEDDED = "0"
        return
    }

    Write-Host "$($script:ESC)[31m[AgentTeams ERROR]$($script:ESC)[0m Embedded controller image is not available in the registry:" -ForegroundColor Red
    Write-Host "  - tried: $versioned" -ForegroundColor Red
    Write-Host "  - tried: $latestTag" -ForegroundColor Red
    Write-Host "" -ForegroundColor Red
    Write-Host "Embedded mode is the only supported architecture since PR #616." -ForegroundColor Red
    Write-Host "How to resolve:" -ForegroundColor Red
    Write-Host "  1) Pin to a AGENTTEAMS_VERSION whose embedded image has been published, or" -ForegroundColor Red
    Write-Host "     wait for the release pipeline to publish it." -ForegroundColor Red
    Write-Host "  2) For a local build, run:  make install-embedded" -ForegroundColor Red
    Write-Host "     (builds and uses the local embedded image without touching the registry)." -ForegroundColor Red
    Write-Host "  3) Override with a custom image:" -ForegroundColor Red
    Write-Host "     `$env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE=...; .\agentteams-install.ps1" -ForegroundColor Red
    Exit-Script 1
}

function Assert-ManagerRuntime {
    $runtime = if ($script:config.MANAGER_RUNTIME) { $script:config.MANAGER_RUNTIME } else { "qwenpaw" }
    $managerOverride = $env:AGENTTEAMS_INSTALL_MANAGER_IMAGE -or $env:AGENTTEAMS_INSTALL_CODEX_WORKER_IMAGE -or $env:AGENTTEAMS_CODEX_WORKER_IMAGE
    $selected = if ($script:AGENTTEAMS_VERSION -eq 'latest') { $script:AGENTTEAMS_KNOWN_STABLE_VERSION } else { $script:AGENTTEAMS_VERSION }
    $selectedMatch = [regex]::Match($selected, '^v?(\d+\.\d+\.\d+)')
    $supportsCodexManager = $selectedMatch.Success -and [version]$selectedMatch.Groups[1].Value -ge [version]'1.2.8'
    if ($runtime -eq "codex" -and -not $supportsCodexManager -and (-not $managerOverride -or -not $env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE)) {
        throw (Get-Msg "manager_runtime.codex_images_required")
    }
    if ($runtime -in @("deepseek-harness", "codex") -and $script:config.MATRIX_E2EE -in @("1", "true")) {
        throw (Get-Msg "manager_runtime.e2ee_unsupported")
    }
}

function Wait-ManagerReady {
    param(
        [string]$Container = "$($script:MANAGER_CONTAINER)",
        [int]$Timeout = $(if ($env:AGENTTEAMS_READY_TIMEOUT) { [int]$env:AGENTTEAMS_READY_TIMEOUT } else { 300 })
    )

    $elapsed = 0
    Write-Log (Get-Msg "install.wait_ready" -f $Timeout)

    $runtime = if ($script:config.MANAGER_RUNTIME) { $script:config.MANAGER_RUNTIME } else { "qwenpaw" }

    while ($elapsed -lt $Timeout) {
        try {
            switch ($runtime) {
                { $_ -in @("copaw", "qwenpaw") } {
                    $result = docker exec $Container curl -sf http://127.0.0.1:18799/api/agents 2>$null
                    if ($result -match '"agents"') {
                        Write-Log (Get-Msg "install.wait_ready.ok")
                        return $true
                    }
                }
                { $_ -in @("hermes", "deepseek-harness", "codex") } {
                    $result = docker exec $script:CONTROLLER_CONTAINER agt get managers default -o json 2>$null
                    if ($LASTEXITCODE -eq 0 -and $result -match '"ready"\s*:\s*true') {
                        Write-Log (Get-Msg "install.wait_ready.ok")
                        return $true
                    }
                }
                default {
                    $result = docker exec $Container openclaw gateway health --json 2>$null
                    if ($LASTEXITCODE -eq 0 -and $result -match '"ok"\s*:\s*true') {
                        Write-Log (Get-Msg "install.wait_ready.ok")
                        return $true
                    }
                }
            }
        } catch {
            # Ignore errors during polling
        }

        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Log (Get-Msg 'install.wait_ready.waiting' -f $elapsed, $Timeout)
    }

    Write-Host ""
    Write-Error (Get-Msg "install.wait_ready.timeout" -f $Timeout, $Container)
}

function Wait-MatrixReady {
    param(
        [string]$Container = "$($script:MANAGER_CONTAINER)",
        [int]$Timeout = $(if ($env:AGENTTEAMS_READY_TIMEOUT) { [int]$env:AGENTTEAMS_READY_TIMEOUT } else { 300 })
    )

    $elapsed = 0
    Write-Log (Get-Msg "install.wait_matrix" -f $Timeout)

    while ($elapsed -lt $Timeout) {
        try {
            $result = docker exec $Container curl -sf http://127.0.0.1:6167/_tuwunel/server_version 2>$null
            if ($result) {
                Write-Log (Get-Msg "install.wait_matrix.ok")
                return $true
            }
        } catch {
            # Ignore errors during polling
        }

        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Log (Get-Msg 'install.wait_matrix.waiting' -f $elapsed, $Timeout)
    }

    Write-Host ""
    Write-Error (Get-Msg "install.wait_matrix.timeout" -f $Timeout, $Container)
}

# Read KEY=value from /data/agentteams-secrets.env on a Docker volume (manager container not required).
# Requires $script:EMBEDDED_IMAGE (set by Resolve-EmbeddedImage before Install-Manager uses this).
function Read-AgentTeamsSecretFromDataVolume {
    param(
        [string]$VolumeName,
        [string]$Key
    )
    if ([string]::IsNullOrEmpty($VolumeName) -or [string]::IsNullOrEmpty($Key) -or [string]::IsNullOrEmpty($script:EMBEDDED_IMAGE)) {
        return ""
    }
    $grepKey = [regex]::Escape($Key)
    $shCmd = "grep ""^${grepKey}="" /data/agentteams-secrets.env 2>/dev/null | cut -d= -f2- | head -1 | tr -d '\r'"
    $out = docker run --rm --entrypoint sh -v "${VolumeName}:/data:ro" $script:EMBEDDED_IMAGE -c $shCmd 2>$null
    if ($null -eq $out) { return "" }
    return ($out | Out-String).Trim()
}

function Test-ExistingEmbeddedController {
    param([string]$ContainerName)
    $entrypoint = docker inspect $ContainerName --format "{{json .Config.Entrypoint}}" 2>$null | Out-String
    return ($entrypoint -match 'supervisord')
}

# Read KEY=value from /data/worker-creds/<worker>.env on a Docker volume.
function Read-AgentTeamsWorkerCredsFromVolume {
    param(
        [string]$VolumeName,
        [string]$WorkerName,
        [string]$Key
    )
    if ([string]::IsNullOrEmpty($VolumeName) -or [string]::IsNullOrEmpty($WorkerName) -or [string]::IsNullOrEmpty($Key) -or [string]::IsNullOrEmpty($script:EMBEDDED_IMAGE)) {
        return ""
    }
    $grepKey = [regex]::Escape($Key)
    $path = "/data/worker-creds/${WorkerName}.env"
    $shCmd = "grep ""^${grepKey}="" ""${path}"" 2>/dev/null | cut -d= -f2- | head -1 | tr -d '\r'"
    $out = docker run --rm --entrypoint sh -v "${VolumeName}:/data:ro" $script:EMBEDDED_IMAGE -c $shCmd 2>$null
    if ($null -eq $out) { return "" }
    return ($out | Out-String).Trim()
}

# Read admin_dm_room_id from host workspace state.json (fallback when Matrix API is unavailable).
function Read-AgentTeamsAdminDmRoomFromWorkspace {
    param([string]$WorkspaceDir)
    if ([string]::IsNullOrEmpty($WorkspaceDir)) { return "" }
    $statePath = Join-Path $WorkspaceDir "state.json"
    if (-not (Test-Path $statePath)) { return "" }
    try {
        $j = Get-Content $statePath -Raw -ErrorAction Stop | ConvertFrom-Json
        $rid = $j.admin_dm_room_id
        if ($null -eq $rid) { return "" }
        $s = [string]$rid
        if ($s -eq "" -or $s -eq "null") { return "" }
        return $s.Trim()
    } catch {
        return ""
    }
}

function Get-AgentTeamsRandomHex {
    param([int]$ByteCount)
    $bytes = New-Object byte[] $ByteCount
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return ([BitConverter]::ToString($bytes)).Replace("-", "").ToLower()
}

# Resolve admin DM room with @manager (small room) via Matrix Client API inside agentteams-manager.
function Get-AgentTeamsAdminDmRoomViaMatrix {
    param(
        [string]$AdminUser,
        [string]$AdminPassword
    )
    $running = docker ps --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
    if (-not $running) { return "" }
    if ([string]::IsNullOrEmpty($AdminPassword)) { return "" }

    $loginObj = @{
        type         = "m.login.password"
        identifier   = @{ type = "m.id.user"; user = $AdminUser }
        password     = $AdminPassword
    }
    $loginJson = $loginObj | ConvertTo-Json -Compress -Depth 5
    try {
        $loginRaw = $loginJson | docker exec -i $($script:MANAGER_CONTAINER) sh -c "curl -sf -X POST http://127.0.0.1:6167/_matrix/client/v3/login -H 'Content-Type: application/json' -d @-" 2>$null
        if (-not $loginRaw) { return "" }
        $loginResp = $loginRaw | ConvertFrom-Json
        $token = [string]$loginResp.access_token
        if ([string]::IsNullOrEmpty($token)) { return "" }

        $roomsRaw = docker exec $($script:MANAGER_CONTAINER) curl -sf -X GET -H "Authorization: Bearer $token" `
            "http://127.0.0.1:6167/_matrix/client/v3/joined_rooms" 2>$null
        if (-not $roomsRaw) { return "" }
        $roomsObj = $roomsRaw | ConvertFrom-Json
        $roomList = @($roomsObj.joined_rooms)
        foreach ($roomId in $roomList) {
            if ([string]::IsNullOrEmpty($roomId)) { continue }
            $enc = $roomId.Replace("!", "%21")
            $memRaw = docker exec $($script:MANAGER_CONTAINER) curl -sf -X GET -H "Authorization: Bearer $token" `
                "http://127.0.0.1:6167/_matrix/client/v3/rooms/${enc}/members" 2>$null
            if (-not $memRaw) { continue }
            $memObj = $memRaw | ConvertFrom-Json
            $chunk = @($memObj.chunk)
            $memberIds = @($chunk | ForEach-Object { $_.state_key })
            $match = $false
            foreach ($m in $memberIds) {
                $beforeColon = ($m -split ":")[0]
                if ($m -like "*manager*" -and $beforeColon -notlike "*admin*") {
                    $match = $true
                    break
                }
            }
            if ($match -and $memberIds.Count -le 3) {
                return $roomId
            }
        }
    } catch {
        return ""
    }
    return ""
}

function New-EnvFile {
    param([hashtable]$Config, [string]$Path)

    $content = @"
# AgentTeams Manager Configuration
# Generated by agentteams-install.ps1 on $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# Language
AGENTTEAMS_LANGUAGE=$($Config.LANGUAGE)
AGENTTEAMS_RESOURCE_PREFIX=$($script:AGENTTEAMS_RESOURCE_PREFIX)
AGENTTEAMS_UNIFIED_ENTRY=$($Config.UNIFIED_ENTRY)
AGENTTEAMS_ENTRY_EXTERNAL_URL=$($Config.ENTRY_EXTERNAL_URL)

# LLM
AGENTTEAMS_LLM_PROVIDER=$($Config.LLM_PROVIDER)
AGENTTEAMS_DEFAULT_MODEL=$($Config.DEFAULT_MODEL)
AGENTTEAMS_LLM_API_KEY=$($Config.LLM_API_KEY)
AGENTTEAMS_OPENAI_BASE_URL=$($Config.OPENAI_BASE_URL)
AGENTTEAMS_MODEL_CONTEXT_WINDOW=$($Config.MODEL_CONTEXT_WINDOW)
AGENTTEAMS_MODEL_MAX_TOKENS=$($Config.MODEL_MAX_TOKENS)
AGENTTEAMS_MODEL_REASONING=$($Config.MODEL_REASONING)
AGENTTEAMS_MODEL_VISION=$($Config.MODEL_VISION)

# Embedding model (empty = disabled, default: text-embedding-v4)
AGENTTEAMS_EMBEDDING_MODEL=$($Config.EMBEDDING_MODEL)

# Admin
AGENTTEAMS_ADMIN_USER=$($Config.ADMIN_USER)
AGENTTEAMS_ADMIN_PASSWORD=$($Config.ADMIN_PASSWORD)

# Ports
AGENTTEAMS_LOCAL_ONLY=$($Config.LOCAL_ONLY)
AGENTTEAMS_PORT_GATEWAY=$($Config.PORT_GATEWAY)
AGENTTEAMS_PORT_CONSOLE=$($Config.PORT_CONSOLE)
AGENTTEAMS_PORT_ELEMENT_WEB=$($Config.PORT_ELEMENT_WEB)
AGENTTEAMS_PORT_MANAGER_CONSOLE=$($Config.PORT_MANAGER_CONSOLE)

# Matrix
AGENTTEAMS_MATRIX_DOMAIN=$($Config.MATRIX_DOMAIN)
AGENTTEAMS_MATRIX_CLIENT_DOMAIN=$($Config.MATRIX_CLIENT_DOMAIN)

# Matrix AppService
AGENTTEAMS_MATRIX_APPSERVICE_ENABLED=$($Config.MATRIX_APPSERVICE_ENABLED)
AGENTTEAMS_MATRIX_APPSERVICE_AS_TOKEN=$($Config.MATRIX_APPSERVICE_AS_TOKEN)
AGENTTEAMS_MATRIX_APPSERVICE_HS_TOKEN=$($Config.MATRIX_APPSERVICE_HS_TOKEN)

# Gateway
AGENTTEAMS_AI_GATEWAY_DOMAIN=$($Config.AI_GATEWAY_DOMAIN)
AGENTTEAMS_MANAGER_GATEWAY_KEY=$($Config.MANAGER_GATEWAY_KEY)

# File System
AGENTTEAMS_FS_DOMAIN=$($Config.FS_DOMAIN)
AGENTTEAMS_CONSOLE_DOMAIN=$($Config.CONSOLE_DOMAIN)
AGENTTEAMS_MINIO_USER=$($Config.MINIO_USER)
AGENTTEAMS_MINIO_PASSWORD=$($Config.MINIO_PASSWORD)

# Internal
AGENTTEAMS_MANAGER_PASSWORD=$($Config.MANAGER_PASSWORD)
AGENTTEAMS_REGISTRATION_TOKEN=$($Config.REGISTRATION_TOKEN)

# GitHub (optional)
AGENTTEAMS_GITHUB_TOKEN=$($Config.GITHUB_TOKEN)

# Nacos package import defaults
AGENTTEAMS_NACOS_REGISTRY_URI=$(if ($env:AGENTTEAMS_NACOS_REGISTRY_URI) { $env:AGENTTEAMS_NACOS_REGISTRY_URI } else { "nacos://market.agentteams.io:80/public" })
AGENTTEAMS_NACOS_USERNAME=$($env:AGENTTEAMS_NACOS_USERNAME)
AGENTTEAMS_NACOS_PASSWORD=$($env:AGENTTEAMS_NACOS_PASSWORD)
AGENTTEAMS_NACOS_TOKEN=$($env:AGENTTEAMS_NACOS_TOKEN)

# Skills Registry (optional, default: nacos://market.agentteams.io:80/public)
AGENTTEAMS_SKILLS_API_URL=$(if ($Config.SKILLS_API_URL) { $Config.SKILLS_API_URL } else { "nacos://market.agentteams.io:80/public" })

# OpenClaw CMS plugin (optional)
AGENTTEAMS_CMS_TRACES_ENABLED=$(if ($env:AGENTTEAMS_CMS_TRACES_ENABLED) { $env:AGENTTEAMS_CMS_TRACES_ENABLED } else { "false" })
AGENTTEAMS_CMS_ENDPOINT=$($env:AGENTTEAMS_CMS_ENDPOINT)
AGENTTEAMS_CMS_LICENSE_KEY=$($env:AGENTTEAMS_CMS_LICENSE_KEY)
AGENTTEAMS_CMS_PROJECT=$($env:AGENTTEAMS_CMS_PROJECT)
AGENTTEAMS_CMS_WORKSPACE=$($env:AGENTTEAMS_CMS_WORKSPACE)
AGENTTEAMS_CMS_SERVICE_NAME=$(if ($env:AGENTTEAMS_CMS_SERVICE_NAME) { $env:AGENTTEAMS_CMS_SERVICE_NAME } else { "$($script:MANAGER_CONTAINER)" })
AGENTTEAMS_CMS_METRICS_ENABLED=$(if ($env:AGENTTEAMS_CMS_METRICS_ENABLED) { $env:AGENTTEAMS_CMS_METRICS_ENABLED } else { "false" })

# Worker images (for direct container creation)
AGENTTEAMS_WORKER_IMAGE=$($Config.WORKER_IMAGE)
AGENTTEAMS_COPAW_WORKER_IMAGE=$($Config.COPAW_WORKER_IMAGE)
AGENTTEAMS_QWENPAW_WORKER_IMAGE=$($Config.QWENPAW_WORKER_IMAGE)
AGENTTEAMS_HERMES_WORKER_IMAGE=$($Config.HERMES_WORKER_IMAGE)
AGENTTEAMS_OPENHUMAN_WORKER_IMAGE=$($Config.OPENHUMAN_WORKER_IMAGE)
AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_IMAGE=$($Config.DEEPSEEK_HARNESS_WORKER_IMAGE)
AGENTTEAMS_CODEX_WORKER_IMAGE=$($Config.CODEX_WORKER_IMAGE)

# Manager runtime (qwenpaw | openclaw | copaw | hermes | deepseek-harness | codex)
AGENTTEAMS_MANAGER_RUNTIME=$($Config.MANAGER_RUNTIME)

# Default Worker runtime (qwenpaw | openclaw | hermes | copaw | deepseek-harness [experimental])
AGENTTEAMS_DEFAULT_WORKER_RUNTIME=$($Config.DEFAULT_WORKER_RUNTIME)

# Matrix E2EE (0=disabled, 1=enabled; default: 0)
AGENTTEAMS_MATRIX_E2EE=$($Config.MATRIX_E2EE)

# Docker API proxy (0=disabled, 1=enabled; default: 1)
AGENTTEAMS_DOCKER_PROXY=$($Config.DOCKER_PROXY)

# Docker API proxy: additional allowed image sources (comma-separated)
AGENTTEAMS_PROXY_ALLOWED_REGISTRIES=$($Config.PROXY_ALLOWED_REGISTRIES)

# Worker idle timeout in minutes (default: 720 = 12 hours)
AGENTTEAMS_WORKER_IDLE_TIMEOUT=$($Config.WORKER_IDLE_TIMEOUT)

# JVM Args for Higress Console
JVM_ARGS=$($env:JVM_ARGS)

# Higress WASM plugins are independent of the regional AgentTeams images.
AGENTTEAMS_HIGRESS_WASM_PLUGIN_REGISTRY=$($Config.HIGRESS_WASM_PLUGIN_REGISTRY)
HIGRESS_ADMIN_WASM_PLUGIN_IMAGE_REGISTRY=$($Config.HIGRESS_WASM_PLUGIN_REGISTRY)

# Data persistence
AGENTTEAMS_DATA_DIR=$($Config.DATA_DIR)
# Manager workspace (skills, memory, state - host-editable)
AGENTTEAMS_WORKSPACE_DIR=$($Config.WORKSPACE_DIR)
# Host directory sharing
AGENTTEAMS_HOST_SHARE_DIR=$($Config.HOST_SHARE_DIR)

# Dashboard
AGENTTEAMS_DASHBOARD=$($Config.DASHBOARD)
AGENTTEAMS_DASHBOARD_VERSION=$($Config.DASHBOARD_VERSION)
AGENTTEAMS_DASHBOARD_IMAGE=$($Config.DASHBOARD_IMAGE)
AGENTTEAMS_PORT_DASHBOARD=$($Config.PORT_DASHBOARD)
"@

    Set-Content -Path $Path -Value $content -Encoding UTF8 -ErrorAction Stop
    Write-Log (Get-Msg "install.config_saved" -f $Path)
}

# ============================================================
# Prompt Functions
# ============================================================

function Read-Prompt {
    param(
        [string]$VarName,
        [string]$PromptText,
        [string]$Default = "",
        [switch]$Secret,
        [switch]$Optional
    )

    # Check if already set in environment
    $envValue = [Environment]::GetEnvironmentVariable($VarName)
    if ($envValue) {
        if ($script:AGENTTEAMS_UPGRADE -and -not $script:AGENTTEAMS_NON_INTERACTIVE) {
            # Show current value (masked for secrets) and let user change it
            $displayValue = $envValue
            if ($Secret) {
                if ($envValue.Length -le 8) {
                    $displayValue = "****"
                } else {
                    $displayValue = $envValue.Substring(0, 4) + "****" + $envValue.Substring($envValue.Length - 4)
                }
            }
            Write-Log (Get-Msg "prompt.upgrade_keep" -f $PromptText, $displayValue)
            $prompt = $PromptText
            if ($Secret) {
                $newValue = Read-Host -Prompt $prompt -AsSecureString
                $newValue = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($newValue)
                )
            } else {
                $newValue = Read-Host -Prompt $prompt
                if ($newValue -eq "b") { $script:StepResult = "back"; return $null }
            }
            if ($newValue) {
                return $newValue
            }
            return $envValue
        }
        Write-Log (Get-Msg "prompt.preset" -f $PromptText)
        return $envValue
    }
    # Upgrade mode: optional fields with empty value — let user set a new value
    elseif ($Optional -and $script:AGENTTEAMS_UPGRADE -and -not $script:AGENTTEAMS_NON_INTERACTIVE) {
        Write-Log (Get-Msg "prompt.upgrade_empty" -f $PromptText)
        $prompt = $PromptText
        if ($Secret) {
            $newValue = Read-Host -Prompt $prompt -AsSecureString
            $newValue = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($newValue)
            )
        } else {
            $newValue = Read-Host -Prompt $prompt
            if ($newValue -eq "b") { $script:StepResult = "back"; return $null }
        }
        if ($newValue) {
            return $newValue
        }
        return ""
    }

    # Non-interactive or quickstart mode
    if ($script:AGENTTEAMS_NON_INTERACTIVE -or $script:AGENTTEAMS_QUICKSTART) {
        if ($Default) {
            Write-Log (Get-Msg "prompt.default" -f $PromptText, $Default)
            return $Default
        }
        elseif ($Optional) {
            return ""
        }
        elseif ($script:AGENTTEAMS_NON_INTERACTIVE) {
            # Only hard-error in fully non-interactive mode, not quickstart
            Write-Error (Get-Msg "prompt.required" -f $PromptText)
        }
        # quickstart + no default + not optional: fall through to interactive prompt
    }

    # Interactive prompt
    $prompt = if ($Default) { "$PromptText [$Default]" } else { $PromptText }

    if ($Secret) {
        $value = Read-Host -Prompt $prompt -AsSecureString
        $value = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($value)
        )
    }
    else {
        $value = Read-Host -Prompt $prompt
        if ($value -eq "b") { $script:StepResult = "back"; return $null }
    }

    if (-not $value -and $Default) {
        $value = $Default
    }

    if (-not $value -and -not $Optional) {
        Write-Error (Get-Msg "prompt.required_empty" -f $PromptText)
    }

    return $value
}

# Load current parameter values from env file for upgrade mode display
function Load-CurrentParamsFromEnv {
    $envFile = $script:AGENTTEAMS_ENV_FILE
    if (Test-Path $envFile) {
        $content = Get-Content $envFile
        $content | ForEach-Object {
            if ($_ -match '^AGENTTEAMS_(DASHBOARD|DASHBOARD_VERSION|DASHBOARD_IMAGE|PORT_DASHBOARD|UNIFIED_ENTRY|ENTRY_EXTERNAL_URL)=(.*)$') {
                $script:config[$Matches[1]] = $Matches[2].Trim()
            }
            if ($_ -match "^AGENTTEAMS_LLM_PROVIDER=(.*)$") {
                $script:config.LLM_PROVIDER = $Matches[1].Trim()
            }
            if ($_ -match "^AGENTTEAMS_OPENAI_BASE_URL=(.*)$") {
                $script:config.OPENAI_BASE_URL = $Matches[1].Trim()
            }
            if ($_ -match "^AGENTTEAMS_DEFAULT_MODEL=(.*)$") {
                $script:config.DEFAULT_MODEL = $Matches[1].Trim()
            }
            if ($_ -match "^AGENTTEAMS_EMBEDDING_MODEL=(.*)$") {
                $script:config.EMBEDDING_MODEL = $Matches[1].Trim()
            }
            if ($_ -match "^AGENTTEAMS_WORKSPACE_DIR=(.*)$") {
                $script:config.WORKSPACE_DIR = $Matches[1].Trim()
            }
            if ($_ -match "^AGENTTEAMS_HOST_SHARE_DIR=(.*)$") {
                $script:config.HOST_SHARE_DIR = $Matches[1].Trim()
            }
            if ($_ -match "^AGENTTEAMS_HIGRESS_WASM_PLUGIN_REGISTRY=(.*)$") {
                $script:config.HIGRESS_WASM_PLUGIN_REGISTRY = $Matches[1].Trim()
            }
        }
    }
}

# ============================================================
# OpenAI-Compatible Provider
# ============================================================

function Test-LlmConnectivity {
    param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Model,
        [string]$Hint = ""
    )
    Write-Log (Get-Msg "llm.openai.test.testing")
    $uri = ($BaseUrl.TrimEnd('/')) + "/chat/completions"
    $bodyHash = @{
        model    = $Model
        messages = @(@{ role = "user"; content = "hi" })
    }
    $body = $bodyHash | ConvertTo-Json -Compress
    try {
        $response = Invoke-WebRequest -Uri $uri -Method POST `
            -Headers @{ "Authorization" = "Bearer $ApiKey"; "Content-Type" = "application/json"; "User-Agent" = "AgentTeams/$($script:AGENTTEAMS_VERSION)" } `
            -Body $body -TimeoutSec 10 -ErrorAction Stop -UseBasicParsing
        $script:ModelConnectionStatus = "ready"
        Write-Log (Get-Msg "llm.openai.test.ok")
    } catch {
        $script:ModelConnectionStatus = "unavailable"
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $responseBody = ""
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
            } catch {}
        }
        Write-Host (Get-Msg "llm.openai.test.fail" -f $statusCode, $responseBody) -ForegroundColor Yellow
        if ($Hint) {
            Write-Host $Hint -ForegroundColor Yellow
        }
        Write-Log (Get-Msg "install.model_unavailable")
    }
}

function Test-EmbeddingConnectivity {
    param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [string]$Model
    )
    Write-Log (Get-Msg "llm.embedding.test.testing")
    $uri = ($BaseUrl.TrimEnd('/')) + "/embeddings"
    $bodyHash = @{
        model = $Model
        input = "test"
    }
    $body = $bodyHash | ConvertTo-Json -Compress
    try {
        $response = Invoke-WebRequest -Uri $uri -Method POST `
            -Headers @{ "Authorization" = "Bearer $ApiKey"; "Content-Type" = "application/json"; "User-Agent" = "AgentTeams/$($script:AGENTTEAMS_VERSION)" } `
            -Body $body -TimeoutSec 30 -ErrorAction Stop -UseBasicParsing
        Write-Log (Get-Msg "llm.embedding.test.ok")
        return $true
    } catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $responseBody = ""
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $responseBody = $reader.ReadToEnd()
            } catch {}
        }
        Write-Host (Get-Msg "llm.embedding.test.fail" -f $statusCode, $responseBody) -ForegroundColor Yellow
        return $false
    }
}

function New-OpenAICompatProvider {
    param(
        [string]$BaseUrl,
        [string]$ApiKey,
        [int]$ConsolePort = 18001
    )

    if (-not $BaseUrl -or -not $ApiKey) {
        Write-Log (Get-Msg "install.openai_compat.missing")
        return $false
    }

    $consoleUrl = "http://localhost:$ConsolePort"

    $uri = [Uri]$BaseUrl
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https')) {
        Write-Log (Get-Msg "install.openai_compat.missing")
        return $false
    }
    $protocol = $uri.Scheme
    $port = $uri.Port
    $domain = $uri.DnsSafeHost
    $sourceType = "dns"
    $ip = $null
    if ([Net.IPAddress]::TryParse($domain, [ref]$ip)) { $sourceType = "static" }
    $urlHost = $domain
    if ($domain.Contains(':')) {
        Write-Log "ERROR: Higress Console static service sources do not support IPv6 endpoints"
        return $false
    }
    $sourceDomain = $domain
    if ($sourceType -eq "static") { $sourceDomain = "${urlHost}:$port" }
    $customUrl = "${protocol}://${urlHost}$($uri.PathAndQuery)$($uri.Fragment)"

    Write-Log (Get-Msg "install.openai_compat.creating")
    Write-Log (Get-Msg "install.openai_compat.domain" -f $domain)
    Write-Log (Get-Msg "install.openai_compat.port" -f $port)
    Write-Log (Get-Msg "install.openai_compat.protocol" -f $protocol)

    $serviceName = "openai-compat"

    try {
        $loginBody = @{ username = $script:config.ADMIN_USER; password = $script:config.ADMIN_PASSWORD } | ConvertTo-Json -Compress
        Invoke-RestMethod -Uri "$consoleUrl/session/login" -Method POST -ContentType "application/json" -Body $loginBody -SessionVariable consoleSession -ErrorAction Stop | Out-Null
    } catch {
        Write-Log (Get-Msg "install.openai_compat.provider_fail")
        return $false
    }

    # Repair an existing source on upgrade, including a previous DNS reference.
    $serviceBody = @{
        type = $sourceType
        name = $serviceName
        port = $port
        protocol = $protocol
        proxyName = ""
        domain = $sourceDomain
    }

    try {
        Invoke-RestMethod -WebSession $consoleSession -Uri "$consoleUrl/v1/service-sources" -Method POST -ContentType "application/json" -Body ($serviceBody | ConvertTo-Json -Compress) -ErrorAction Stop | Out-Null
    }
    catch {
        if ([int]$_.Exception.Response.StatusCode -ne 409) {
            Write-Log (Get-Msg "install.openai_compat.service_fail")
            return $false
        }
        $existing = Invoke-RestMethod -WebSession $consoleSession -Uri "$consoleUrl/v1/service-sources/$serviceName" -Method GET -ErrorAction Stop
        $serviceBody.version = $existing.data.version
        foreach ($property in $existing.data.PSObject.Properties) {
            if (-not $serviceBody.ContainsKey($property.Name)) { $serviceBody[$property.Name] = $property.Value }
        }
        Invoke-RestMethod -WebSession $consoleSession -Uri "$consoleUrl/v1/service-sources/$serviceName" -Method PUT -ContentType "application/json" -Body ($serviceBody | ConvertTo-Json -Compress) -ErrorAction Stop | Out-Null
    }

    Start-Sleep -Seconds 2

    # Create AI provider
    $providerBody = @{
        type = "openai"
        name = "openai-compat"
        tokens = @($ApiKey)
        version = 0
        protocol = "openai/v1"
        tokenFailoverConfig = @{ enabled = $false }
        rawConfigs = @{
            openaiCustomUrl = $customUrl
            openaiCustomServiceName = "$serviceName.$sourceType"
            openaiCustomServicePort = $port
        }
    }

    try {
        Invoke-RestMethod -WebSession $consoleSession -Uri "$consoleUrl/v1/ai/providers" -Method POST -ContentType "application/json" -Body ($providerBody | ConvertTo-Json -Compress -Depth 3) -ErrorAction Stop | Out-Null
        Write-Log (Get-Msg "install.openai_compat.success")
        return $true
    }
    catch {
        if ([int]$_.Exception.Response.StatusCode -eq 409) {
            $existing = Invoke-RestMethod -WebSession $consoleSession -Uri "$consoleUrl/v1/ai/providers/$serviceName" -Method GET -ErrorAction Stop
            $providerBody.version = $existing.data.version
            foreach ($property in $existing.data.PSObject.Properties) {
                if (-not $providerBody.ContainsKey($property.Name)) { $providerBody[$property.Name] = $property.Value }
            }
            foreach ($property in $existing.data.rawConfigs.PSObject.Properties) {
                if (-not $providerBody.rawConfigs.ContainsKey($property.Name)) { $providerBody.rawConfigs[$property.Name] = $property.Value }
            }
            Invoke-RestMethod -WebSession $consoleSession -Uri "$consoleUrl/v1/ai/providers/$serviceName" -Method PUT -ContentType "application/json" -Body ($providerBody | ConvertTo-Json -Compress -Depth 3) -ErrorAction Stop | Out-Null
            return $true
        }
        Write-Log (Get-Msg "install.openai_compat.provider_fail")
        return $false
    }
}

# ============================================================
# State Machine Helpers
# ============================================================

function Test-ShouldSkipStep {
    param([string]$StepFn)
    if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_UPGRADE_KEEP_ALL -eq "1" -and $StepFn -notin @("Step-Lang", "Step-Mode", "Step-Existing")) { return $true }
    if ($script:AGENTTEAMS_QUICKSTART) {
        if ($StepFn -in @("Step-Lang", "Step-Mode")) { return $true }
        if (-not $script:AGENTTEAMS_UPGRADE -and $StepFn -in @("Step-Runtime", "Step-ManagerRuntime", "Step-Network", "Step-E2ee", "Step-DockerProxy", "Step-Idle", "Step-Hostshare")) { return $true }
    }
    switch ($StepFn) {
        { $_ -in @("Step-Lang", "Step-Mode") } {
            return $script:AGENTTEAMS_NON_INTERACTIVE
        }
        "Step-Existing" {
            return (-not (Test-Path $script:AGENTTEAMS_ENV_FILE) -and -not $script:RecoveredConfig)
        }
        # Keep-All upgrade mode: skip all config steps, values are already loaded
        { $_ -in @("Step-Llm", "Step-Admin", "Step-Network", "Step-Ports", "Step-Domains",
                    "Step-Github", "Step-Skills",
                    "Step-Runtime", "Step-ManagerRuntime", "Step-E2ee", "Step-DockerProxy",
                    "Step-Idle", "Step-Hostshare") } {
            if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_UPGRADE_KEEP_ALL -eq "1") { return $true }
            return $false
        }
        { $_ -in @("Step-Volume", "Step-Workspace") } {
            if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_UPGRADE_KEEP_ALL -eq "1") { return $true }
            if ($script:AGENTTEAMS_NON_INTERACTIVE) { return $true }
            if ($script:AGENTTEAMS_QUICKSTART) { return $true }
            return $false
        }
        { $_ -in @("Step-E2ee", "Step-Idle") } {
            if ($script:AGENTTEAMS_NON_INTERACTIVE) { return $true }
            if ($script:AGENTTEAMS_QUICKSTART -and -not $script:AGENTTEAMS_UPGRADE) { return $true }
            return $false
        }
        "Step-DockerProxy" {
            # Embedded controller IS the proxy/orchestrator — no separate proxy step needed.
            if ($script:AGENTTEAMS_USE_EMBEDDED -eq "1") { return $true }
            if ($script:AGENTTEAMS_NON_INTERACTIVE) { return $true }
            if ($script:AGENTTEAMS_QUICKSTART -and -not $script:AGENTTEAMS_UPGRADE) { return $true }
            return $false
        }
        "Step-ManagerRuntime" {
            if ($script:AGENTTEAMS_NON_INTERACTIVE) { return $true }
            return $false
        }
        "Step-Hostshare" {
            if ($script:AGENTTEAMS_NON_INTERACTIVE) { return $true }
            if ($script:AGENTTEAMS_QUICKSTART) { return $true }
            return $false
        }
        default { return $false }
    }
}

function Clear-StepVars {
    param([string]$StepFn)
    switch ($StepFn) {
        "Step-Mode" { $script:AGENTTEAMS_QUICKSTART = $false }
        "Step-Existing" {
            $script:AGENTTEAMS_UPGRADE = $false
            $script:UPGRADE_EXISTING_WORKERS = $null
        }
        "Step-Llm" {
            foreach ($k in @("AGENTTEAMS_LLM_PROVIDER","AGENTTEAMS_DEFAULT_MODEL","AGENTTEAMS_OPENAI_BASE_URL",
                             "AGENTTEAMS_LLM_API_KEY","AGENTTEAMS_MODEL_CONTEXT_WINDOW","AGENTTEAMS_MODEL_MAX_TOKENS",
                             "AGENTTEAMS_MODEL_REASONING","AGENTTEAMS_MODEL_VISION")) {
                [Environment]::SetEnvironmentVariable($k, $null, "Process")
            }
        }
        "Step-Admin" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_ADMIN_USER", $null, "Process")
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_ADMIN_PASSWORD", $null, "Process")
        }
        "Step-Network" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_LOCAL_ONLY", $null, "Process")
        }
        "Step-Ports" {
            foreach ($k in @("AGENTTEAMS_PORT_GATEWAY","AGENTTEAMS_PORT_CONSOLE","AGENTTEAMS_PORT_ELEMENT_WEB","AGENTTEAMS_PORT_MANAGER_CONSOLE")) {
                [Environment]::SetEnvironmentVariable($k, $null, "Process")
            }
        }
        "Step-Domains" {
            foreach ($k in @("AGENTTEAMS_MATRIX_DOMAIN","AGENTTEAMS_MATRIX_CLIENT_DOMAIN","AGENTTEAMS_AI_GATEWAY_DOMAIN","AGENTTEAMS_FS_DOMAIN","AGENTTEAMS_CONSOLE_DOMAIN")) {
                [Environment]::SetEnvironmentVariable($k, $null, "Process")
            }
        }
        "Step-Github" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_GITHUB_TOKEN", $null, "Process")
        }
        "Step-Skills" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_SKILLS_API_URL", $null, "Process")
        }
        "Step-Volume" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_DATA_DIR", $null, "Process")
        }
        "Step-Workspace" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_WORKSPACE_DIR", $null, "Process")
        }
        "Step-Runtime" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_DEFAULT_WORKER_RUNTIME", $null, "Process")
        }
        "Step-ManagerRuntime" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_MANAGER_RUNTIME", $null, "Process")
        }
        "Step-E2ee" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_MATRIX_E2EE", $null, "Process")
        }
        "Step-DockerProxy" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_DOCKER_PROXY", $null, "Process")
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_PROXY_ALLOWED_REGISTRIES", $null, "Process")
        }
        "Step-Idle" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_WORKER_IDLE_TIMEOUT", $null, "Process")
        }
        "Step-Hostshare" {
            [Environment]::SetEnvironmentVariable("AGENTTEAMS_HOST_SHARE_DIR", $null, "Process")
        }
    }
}

# ============================================================
# Individual step functions
# ============================================================

function Step-Lang {
    $langDefaultChoice = if ($script:AGENTTEAMS_LANGUAGE -eq "zh") { "1" } else { "2" }
    $langDetectedKey = "lang.detected.$($script:AGENTTEAMS_LANGUAGE)"
    Write-Log (Get-Msg $langDetectedKey)
    Write-Log (Get-Msg "lang.switch_title")
    Write-Host (Get-Msg "lang.option_zh")
    Write-Host (Get-Msg "lang.option_en")
    Write-Host ""
    $langChoice = Read-Host "$(Get-Msg 'lang.prompt') [$langDefaultChoice]"
    if (-not $langChoice) { $langChoice = $langDefaultChoice }
    if ($langChoice -eq "b") { $script:StepResult = "back"; return }
    switch ($langChoice) {
        "1" { $script:AGENTTEAMS_LANGUAGE = "zh" }
        "2" { $script:AGENTTEAMS_LANGUAGE = "en" }
    }
    $env:AGENTTEAMS_LANGUAGE = $script:AGENTTEAMS_LANGUAGE
    Write-Log ""
}

function Step-Mode {
    Write-Log (Get-Msg "install.mode.title")
    Write-Host ""
    Write-Host (Get-Msg "install.mode.choose")
    Write-Host (Get-Msg "install.mode.quickstart")
    Write-Host (Get-Msg "install.mode.manual")
    Write-Host ""
    $choice = Read-Host (Get-Msg "install.mode.prompt")
    $choice = if ($choice) { $choice } else { "1" }
    if ($choice -eq "b") { $script:StepResult = "back"; return }
    switch -Regex ($choice) {
        "^(1|quick|quickstart)$" {
            Write-Log (Get-Msg "install.mode.quickstart_selected")
            $script:AGENTTEAMS_QUICKSTART = $true
        }
        "^(2|manual)$" {
            Write-Log (Get-Msg "install.mode.manual_selected")
            $script:AGENTTEAMS_QUICKSTART = $false
        }
        default {
            Write-Log (Get-Msg "install.mode.invalid")
            $script:AGENTTEAMS_QUICKSTART = $true
        }
    }
    Write-Log ""
}

function Load-UpgradeConfig {
    $lines = if (Test-Path $script:AGENTTEAMS_ENV_FILE) { Get-Content -LiteralPath $script:AGENTTEAMS_ENV_FILE } else { $script:RecoveredConfig }
    foreach ($line in $lines) {
        if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { continue }
        $key, $value = $Matches[1], $Matches[2]
        if (($key -notlike 'AGENTTEAMS_*' -and $key -notin @('JVM_ARGS', 'DASHBOARD_SESSION_SECRET')) -or $key -eq 'AGENTTEAMS_VERSION') { continue }
        if ($script:InstallEnvKeys.ContainsKey($key)) { $value = [Environment]::GetEnvironmentVariable($key, 'Process') }
        else { [Environment]::SetEnvironmentVariable($key, $value, 'Process') }
        if ($key -eq 'AGENTTEAMS_REGISTRY') { $script:AGENTTEAMS_REGISTRY = $value }
        if ($key -like 'AGENTTEAMS_*') { $script:config[$key.Substring(11)] = $value }
    }
}

function Prepare-UpgradeDashboard {
    if (-not $script:config.DASHBOARD) { $script:config.DASHBOARD = '1' }
    if ($script:InstallEnvKeys.ContainsKey('AGENTTEAMS_DASHBOARD_VERSION') -or $script:InstallEnvKeys.ContainsKey('AGENTTEAMS_DASHBOARD_IMAGE')) { return }
    $oldVersion = $script:config.DASHBOARD_VERSION
    $oldImage = $script:config.DASHBOARD_IMAGE
    if ($oldVersion -in @($null, '', 'v1.2.4', 'v1.3.1', 'v1.4.0', 'v1.4.1', 'v1.4.2') -and
        (-not $oldImage -or $oldImage -in @("$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-dashboard:$oldVersion", "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-dashboard:$oldVersion-unified"))) {
        $script:config.DASHBOARD_VERSION = 'v1.4.3'
        $script:config.DASHBOARD_IMAGE = "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-dashboard:v1.4.3"
        $env:AGENTTEAMS_DASHBOARD_VERSION = $script:config.DASHBOARD_VERSION
        $env:AGENTTEAMS_DASHBOARD_IMAGE = $script:config.DASHBOARD_IMAGE
    }
}

function Get-InstalledStorage {
    param([string]$Container = "$($script:CONTROLLER_CONTAINER)")
    try {
        $raw = docker inspect $Container --format '{{json .Mounts}}' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $raw) { return $null }
        $mounts = ($raw | Out-String) | ConvertFrom-Json -ErrorAction Stop
        $data = $mounts | Where-Object Destination -eq '/data' | Select-Object -First 1
        $workspace = $mounts | Where-Object { $_.Destination -in @('/root/agentteams-fs/agents/manager', '/root/manager-workspace') } | Select-Object -First 1
        return @{ Data = $(if ($data.Type -eq 'volume') { $data.Name } else { $data.Source }); Workspace = $workspace.Source }
    } catch { return $null }
}

function Recover-ExistingInstall {
    $names = @(docker ps -a --format '{{.Names}}' 2>$null)
    $container = if ($names -contains "$($script:CONTROLLER_CONTAINER)") { "$($script:CONTROLLER_CONTAINER)" } elseif ($names -contains "$($script:MANAGER_CONTAINER)") { "$($script:MANAGER_CONTAINER)" } else { $null }
    if (-not $container) {
        $data = if ($env:AGENTTEAMS_DATA_DIR) { $env:AGENTTEAMS_DATA_DIR } else { "$($script:DEFAULT_DATA_VOLUME)" }
        docker volume inspect $data *> $null
        if ($LASTEXITCODE -eq 0 -or ((Test-Path -LiteralPath $data -PathType Container) -and (Get-ChildItem -LiteralPath $data -Force | Select-Object -First 1))) { Write-Error (Get-Msg 'upgrade.recovery_failed') }
        return
    }
    try {
        $raw = docker inspect $container --format '{{json .Config.Env}}' 2>$null
        $saved = @(($raw | Out-String) | ConvertFrom-Json -ErrorAction Stop)
    } catch { Write-Error (Get-Msg 'upgrade.recovery_failed') }
    $storage = Get-InstalledStorage $container
    if (-not $storage.Data -or -not $storage.Workspace) { Write-Error (Get-Msg 'upgrade.recovery_failed') }
    $required = @('ADMIN_USER', 'ADMIN_PASSWORD', 'MANAGER_PASSWORD', 'REGISTRATION_TOKEN', 'MINIO_USER', 'MINIO_PASSWORD', 'MANAGER_GATEWAY_KEY')
    if ($saved -notcontains 'AGENTTEAMS_MATRIX_APPSERVICE_ENABLED=false' -and $saved -notcontains 'AGENTTEAMS_MATRIX_APPSERVICE_ENABLED=0') { $required += @('MATRIX_APPSERVICE_AS_TOKEN', 'MATRIX_APPSERVICE_HS_TOKEN') }
    foreach ($key in $required) {
        if (-not ($saved | Where-Object { $_ -match "^AGENTTEAMS_${key}=.+" })) { Write-Error (Get-Msg 'upgrade.recovery_failed') }
    }
    if (-not ($saved -match '^AGENTTEAMS_UNIFIED_ENTRY=') -and ($saved -contains 'AGENTTEAMS_UNIFIED_ENTRY_ENABLED=true' -or $saved -contains 'AGENTTEAMS_UNIFIED_ENTRY_ENABLED=1')) {
        $saved += 'AGENTTEAMS_UNIFIED_ENTRY=1'
    }
    $script:RecoveredConfig = $saved + @("AGENTTEAMS_DATA_DIR=$($storage.Data)", "AGENTTEAMS_WORKSPACE_DIR=$($storage.Workspace)")
    Write-Log (Get-Msg 'upgrade.recovered')
}

function Step-Existing {
    # This step is skipped when env file doesn't exist
    Write-Log (Get-Msg "install.existing.detected" -f $script:AGENTTEAMS_ENV_FILE)

    $runningManager = docker ps --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
    $runningWorkers = docker ps --format "{{.Names}}" 2>$null | Select-String "^$($script:WORKER_CONTAINER_PREFIX)"
    $existingWorkers = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:WORKER_CONTAINER_PREFIX)"

    Load-UpgradeConfig
    if (-not $script:InstallEnvKeys.ContainsKey('AGENTTEAMS_MANAGER_RUNTIME')) {
        $installedRuntime = docker inspect $script:MANAGER_CONTAINER --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null | Where-Object { $_ -match '^AGENTTEAMS_MANAGER_RUNTIME=' } | Select-Object -First 1
        if ($installedRuntime) {
            $script:config.MANAGER_RUNTIME = ($installedRuntime -split '=', 2)[1]
            $env:AGENTTEAMS_MANAGER_RUNTIME = $script:config.MANAGER_RUNTIME
        }
    }
    $storage = Get-InstalledStorage
    if ($storage.Data) {
        if ($script:config.DATA_DIR -and $script:config.DATA_DIR -ne $storage.Data) { Write-Error (Get-Msg 'upgrade.recovery_failed') }
        $script:config.DATA_DIR = $storage.Data
    }
    if (-not $script:config.WORKSPACE_DIR -and $storage.Workspace) { $script:config.WORKSPACE_DIR = $storage.Workspace }
    foreach ($key in @('ADMIN_USER', 'ADMIN_PASSWORD', 'MANAGER_PASSWORD', 'REGISTRATION_TOKEN', 'MINIO_USER', 'MINIO_PASSWORD', 'MANAGER_GATEWAY_KEY', 'DATA_DIR', 'WORKSPACE_DIR')) {
        if (-not $script:config[$key]) { Write-Error (Get-Msg 'upgrade.recovery_failed') }
    }
    if ($script:config.MATRIX_APPSERVICE_ENABLED -notin @('false', '0') -and (-not $script:config.MATRIX_APPSERVICE_AS_TOKEN -or -not $script:config.MATRIX_APPSERVICE_HS_TOKEN)) { Write-Error (Get-Msg 'upgrade.recovery_failed') }
    docker volume inspect $script:config.DATA_DIR *> $null
    if ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $script:config.DATA_DIR -PathType Container)) { Write-Error (Get-Msg 'upgrade.recovery_failed') }
    $upgradeChoice = if ($Command -eq 'reinstall') { 'reinstall' } else { 'upgrade' }
    switch ($upgradeChoice) {
        'upgrade' {
            $script:AGENTTEAMS_UPGRADE = $true
            $env:AGENTTEAMS_UPGRADE_KEEP_ALL = '1'
            Prepare-UpgradeDashboard
            $image = docker inspect $($script:CONTROLLER_CONTAINER) --format '{{.Config.Image}}' 2>$null
            if (-not $image) { $image = docker inspect $($script:MANAGER_CONTAINER) --format '{{.Config.Image}}' 2>$null }
            Write-Log (Get-Msg 'upgrade.summary' -f ($image -split ':')[-1], $script:AGENTTEAMS_VERSION)
            if (-not $script:AGENTTEAMS_NON_INTERACTIVE) {
                $confirm = Read-Host (Get-Msg 'upgrade.confirm')
                if ($confirm -and $confirm -notmatch '^(y|yes)$') {
                    Write-Log (Get-Msg 'install.existing.cancelled')
                    exit 0
                }
            }
            $script:UPGRADE_EXISTING_WORKERS = $existingWorkers
        }
        'reinstall' {
            Write-Log (Get-Msg "install.reinstall.performing")
            $existingWorkspace = "$env:USERPROFILE\$($script:MANAGER_CONTAINER)"
            if (Test-Path $script:AGENTTEAMS_ENV_FILE) {
                $envContent = Get-Content $script:AGENTTEAMS_ENV_FILE
                $wsLine = $envContent | Select-String "^AGENTTEAMS_WORKSPACE_DIR="
                if ($wsLine) {
                    $existingWorkspace = $wsLine.Line.Substring(21)
                }
            }
            Write-Host ""
            Write-Host "$($script:ESC)[33m$(Get-Msg 'install.reinstall.warn_stop')$($script:ESC)[0m"
            if ($runningManager) { Write-Host "$($script:ESC)[33m   - $($script:MANAGER_CONTAINER) (manager)$($script:ESC)[0m" }
            $runningWorkers | ForEach-Object { Write-Host "$($script:ESC)[33m   - $_ (worker)$($script:ESC)[0m" }
            Write-Host ""
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.warn_delete')$($script:ESC)[0m"
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.warn_volume')$($script:ESC)[0m"
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.warn_env' -f $script:AGENTTEAMS_ENV_FILE)$($script:ESC)[0m"
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.warn_workspace' -f $existingWorkspace)$($script:ESC)[0m"
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.warn_workers')$($script:ESC)[0m"
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.warn_proxy')$($script:ESC)[0m"
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.warn_network')$($script:ESC)[0m"
            Write-Host ""
            Write-Host "$($script:ESC)[31m$(Get-Msg 'install.reinstall.confirm_type')$($script:ESC)[0m"
            Write-Host "$($script:ESC)[31m  $existingWorkspace$($script:ESC)[0m"
            Write-Host ""
            $confirmPath = Read-Host (Get-Msg "install.reinstall.confirm_path")
            if ($confirmPath -ne $existingWorkspace) {
                Write-Error (Get-Msg "install.reinstall.path_mismatch" -f $confirmPath, $existingWorkspace)
            }
            Write-Log (Get-Msg "install.reinstall.confirmed")
            docker stop $($script:MANAGER_CONTAINER) *>$null
            docker rm $($script:MANAGER_CONTAINER) *>$null
            docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:WORKER_CONTAINER_PREFIX)" | ForEach-Object {
                docker stop $_ *>$null
                docker rm $_ *>$null
                Write-Log (Get-Msg "install.reinstall.removed_worker" -f $_)
            }
            $existingController = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:CONTROLLER_CONTAINER)$"
            if ($existingController) {
                Write-Log (Get-Msg "install.reinstall.removing_proxy")
                docker stop $($script:CONTROLLER_CONTAINER) *>$null
                docker rm $($script:CONTROLLER_CONTAINER) *>$null
            }
            if (docker volume ls -q 2>$null | Select-String "^$($script:DEFAULT_DATA_VOLUME)$") {
                Write-Log (Get-Msg "install.reinstall.removing_volume")
                docker volume rm $($script:DEFAULT_DATA_VOLUME) *>$null
            }
            if (Test-Path $existingWorkspace) {
                Write-Log (Get-Msg "install.reinstall.removing_workspace" -f $existingWorkspace)
                Remove-Item -Recurse -Force $existingWorkspace
            }
            if (Test-Path $script:AGENTTEAMS_ENV_FILE) {
                Write-Log (Get-Msg "install.reinstall.removing_env" -f $script:AGENTTEAMS_ENV_FILE)
                Remove-Item -Force $script:AGENTTEAMS_ENV_FILE
            }
            $existingNetwork = docker network ls --format "{{.Name}}" 2>$null | Select-String "^$($script:DOCKER_NETWORK)$"
            if ($existingNetwork) {
                Write-Log (Get-Msg "install.reinstall.removing_network")
                docker network rm $($script:DOCKER_NETWORK) *>$null
            }
            Write-Log (Get-Msg "install.reinstall.cleanup_done")
        }
        default {
            Write-Log (Get-Msg "install.existing.cancelled")
            exit 0
        }
    }


}

function Step-Llm {
    Write-Log (Get-Msg "llm.title")

    if ($script:AGENTTEAMS_NON_INTERACTIVE -or $script:AGENTTEAMS_QUICKSTART) {
        if ($script:AGENTTEAMS_LANGUAGE -eq "zh") {
            $script:config.LLM_PROVIDER = if ($env:AGENTTEAMS_LLM_PROVIDER) { $env:AGENTTEAMS_LLM_PROVIDER } else { "openai-compat" }
            $script:config.DEFAULT_MODEL = if ($env:AGENTTEAMS_DEFAULT_MODEL) { $env:AGENTTEAMS_DEFAULT_MODEL } else { "qwen3.6-plus" }
            $script:config.OPENAI_BASE_URL = if ($env:AGENTTEAMS_OPENAI_BASE_URL) { $env:AGENTTEAMS_OPENAI_BASE_URL } else { "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1" }
            Write-Log (Get-Msg "llm.provider.label" -f $script:config.LLM_PROVIDER)
            Write-Log (Get-Msg "llm.openai.base_url_label" -f $script:config.OPENAI_BASE_URL)
        } else {
            $script:config.LLM_PROVIDER = if ($env:AGENTTEAMS_LLM_PROVIDER) { $env:AGENTTEAMS_LLM_PROVIDER } else { "qwen" }
            $script:config.DEFAULT_MODEL = if ($env:AGENTTEAMS_DEFAULT_MODEL) { $env:AGENTTEAMS_DEFAULT_MODEL } else { "qwen3.6-plus" }
            $script:config.OPENAI_BASE_URL = if ($env:AGENTTEAMS_OPENAI_BASE_URL) { $env:AGENTTEAMS_OPENAI_BASE_URL } else { "" }
            Write-Log (Get-Msg "llm.provider.qwen_default" -f $script:config.LLM_PROVIDER)
        }
        Write-Log (Get-Msg "llm.model.label" -f $script:config.DEFAULT_MODEL)
        Write-Log ""
        $script:config.LLM_API_KEY = $env:AGENTTEAMS_LLM_API_KEY
        $script:config.EMBEDDING_MODEL = $env:AGENTTEAMS_EMBEDDING_MODEL
        return
    }

    Write-Host ""
    Write-Host (Get-Msg "llm.providers_title")
    Write-Host (Get-Msg "llm.provider.alibaba")
    Write-Host (Get-Msg "llm.provider.openai_compat")
    Write-Host ""

    # If upgrade mode with loaded provider, show current as default
    if ($script:AGENTTEAMS_UPGRADE -and $script:config.LLM_PROVIDER) {
        $defaultProvider = if ($script:config.LLM_PROVIDER -eq "openai-compat") { "2" } else { "1" }
        $providerChoice = Read-Host "$(Get-Msg 'llm.provider.select') [${defaultProvider}]"
        $providerChoice = if ($providerChoice) { $providerChoice } else { $defaultProvider }
    } elseif ($script:AGENTTEAMS_QUICKSTART) {
        $providerChoice = Read-Host "$(Get-Msg 'llm.provider.select') [1]"
    } else {
        $providerChoice = Read-Host (Get-Msg "llm.provider.select")
        $providerChoice = if ($providerChoice) { $providerChoice } else { "1" }
    }
    if ($providerChoice -eq "b") { $script:StepResult = "back"; return }

    switch -Regex ($providerChoice) {
        "^(1|alibaba-cloud)$" {
            $alibabaAccess = $null
            if ($script:AGENTTEAMS_LANGUAGE -eq "en") {
                $script:config.LLM_PROVIDER = "openai-compat"
                $script:config.OPENAI_BASE_URL = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
                $alibabaAccess = "tokenplan"
                Write-Host ""
                Write-Host (Get-Msg "llm.codingplan.models_title")
                Write-Host (Get-Msg "llm.codingplan.model.qwen36plus")
                Write-Host (Get-Msg "llm.codingplan.model.glm5")
                Write-Host (Get-Msg "llm.codingplan.model.kimi")
                Write-Host (Get-Msg "llm.codingplan.model.minimax")
                Write-Host ""
                # If upgrade with loaded model, show current as default
                if ($script:AGENTTEAMS_UPGRADE -and $script:config.DEFAULT_MODEL) {
                    $defaultModel = switch ($script:config.DEFAULT_MODEL) {
                        "qwen3.6-plus" { "1" }
                        "glm-5"         { "2" }
                        "glm-5.2"       { "2" }
                        "kimi-k2.5"     { "3" }
                        "MiniMax-M2.5"  { "4" }
                        default         { "1" }
                    }
                    $codingPlanModelChoice = Read-Host "$(Get-Msg 'llm.codingplan.model.select') [${defaultModel}]"
                    $codingPlanModelChoice = if ($codingPlanModelChoice) { $codingPlanModelChoice } else { $defaultModel }
                } elseif ($script:AGENTTEAMS_QUICKSTART) {
                    $codingPlanModelChoice = Read-Host "$(Get-Msg 'llm.codingplan.model.select') [1]"
                } else {
                    $codingPlanModelChoice = Read-Host (Get-Msg "llm.codingplan.model.select")
                }
                $codingPlanModelChoice = if ($codingPlanModelChoice) { $codingPlanModelChoice } else { "1" }
                if ($codingPlanModelChoice -eq "b") { $script:StepResult = "back"; return }
                switch -Regex ($codingPlanModelChoice) {
                    "^(1|qwen3\.6-plus)$"  { $script:config.DEFAULT_MODEL = "qwen3.6-plus" }
                    "^(2|glm-5|glm-5\.2)$"  { $script:config.DEFAULT_MODEL = "glm-5.2" }
                    "^(3|kimi-k2\.5)$"     { $script:config.DEFAULT_MODEL = "kimi-k2.5" }
                    "^(4|MiniMax-M2\.5)$"  { $script:config.DEFAULT_MODEL = "MiniMax-M2.5" }
                    default                { $script:config.DEFAULT_MODEL = "qwen3.6-plus" }
                }
                Write-Log (Get-Msg "llm.provider.selected_codingplan")
            } else {
                Write-Host ""
                Write-Host (Get-Msg "llm.alibaba.models_title")
                Write-Host (Get-Msg "llm.alibaba.model.tokenplan")
                Write-Host (Get-Msg "llm.alibaba.model.bailian")
                Write-Host (Get-Msg "llm.alibaba.model.codingplan_legacy")
                Write-Host ""
                $modelChoice = if ($script:AGENTTEAMS_QUICKSTART) {
                    Read-Host "$(Get-Msg 'llm.alibaba.model.select') [1]"
                } else {
                    Read-Host (Get-Msg "llm.alibaba.model.select")
                }
                $modelChoice = if ($modelChoice) { $modelChoice } else { "1" }
                if ($modelChoice -eq "b") { $script:StepResult = "back"; return }

                if ($modelChoice -match "^(1|token-plan|tokenplan)$") {
                    $alibabaAccess = "tokenplan"
                    $script:config.LLM_PROVIDER = "openai-compat"
                    $script:config.OPENAI_BASE_URL = "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
                    Write-Host ""
                    Write-Host (Get-Msg "llm.codingplan.models_title")
                    Write-Host (Get-Msg "llm.codingplan.model.qwen36plus")
                    Write-Host (Get-Msg "llm.codingplan.model.glm5")
                    Write-Host (Get-Msg "llm.codingplan.model.kimi")
                    Write-Host (Get-Msg "llm.codingplan.model.minimax")
                    Write-Host ""
                    # If upgrade with loaded model, show current as default
                    if ($script:AGENTTEAMS_UPGRADE -and $script:config.DEFAULT_MODEL) {
                        $defaultModel = switch ($script:config.DEFAULT_MODEL) {
                            "qwen3.6-plus" { "1" }
                            "glm-5"         { "2" }
                            "glm-5.2"       { "2" }
                            "kimi-k2.5"     { "3" }
                            "MiniMax-M2.5"  { "4" }
                            default         { "1" }
                        }
                        $codingPlanModelChoice = Read-Host "$(Get-Msg 'llm.codingplan.model.select') [${defaultModel}]"
                        $codingPlanModelChoice = if ($codingPlanModelChoice) { $codingPlanModelChoice } else { $defaultModel }
                    } elseif ($script:AGENTTEAMS_QUICKSTART) {
                        $codingPlanModelChoice = Read-Host "$(Get-Msg 'llm.codingplan.model.select') [1]"
                    } else {
                        $codingPlanModelChoice = Read-Host (Get-Msg "llm.codingplan.model.select")
                    }
                    $codingPlanModelChoice = if ($codingPlanModelChoice) { $codingPlanModelChoice } else { "1" }
                    if ($codingPlanModelChoice -eq "b") { $script:StepResult = "back"; return }
                    switch -Regex ($codingPlanModelChoice) {
                        "^(1|qwen3\.6-plus)$"  { $script:config.DEFAULT_MODEL = "qwen3.6-plus" }
                        "^(2|glm-5|glm-5\.2)$"  { $script:config.DEFAULT_MODEL = "glm-5.2" }
                        "^(3|kimi-k2\.5)$"     { $script:config.DEFAULT_MODEL = "kimi-k2.5" }
                        "^(4|MiniMax-M2\.5)$"  { $script:config.DEFAULT_MODEL = "MiniMax-M2.5" }
                        default                { $script:config.DEFAULT_MODEL = "qwen3.6-plus" }
                    }
                    Write-Log (Get-Msg "llm.provider.selected_tokenplan")
                } elseif ($modelChoice -match "^(2|qwen|bailian)$") {
                    $alibabaAccess = "bailian"
                    $script:config.LLM_PROVIDER = "qwen"
                    $script:config.OPENAI_BASE_URL = ""
                    Write-Host ""
                    if ($script:AGENTTEAMS_UPGRADE -and $script:config.DEFAULT_MODEL) {
                        $qwenModelInput = Read-Host "$(Get-Msg 'llm.qwen.model_prompt') [${script:config.DEFAULT_MODEL}]"
                    } else {
                        $qwenModelInput = Read-Host (Get-Msg "llm.qwen.model_prompt")
                    }
                    if ($qwenModelInput -eq "b") { $script:StepResult = "back"; return }
                    $script:config.DEFAULT_MODEL = if ($qwenModelInput) { $qwenModelInput } elseif ($script:config.DEFAULT_MODEL) { $script:config.DEFAULT_MODEL } else { "qwen3.6-plus" }
                    Write-Log (Get-Msg "llm.provider.selected_qwen")
                    Request-CustomModelParams $script:config.DEFAULT_MODEL
                    if ($script:StepResult -eq "back") { return }
                } elseif ($modelChoice -match "^(3|coding-plan|codingplan)$") {
                    $alibabaAccess = "codingplan_legacy"
                    $script:config.LLM_PROVIDER = "openai-compat"
                    $script:config.OPENAI_BASE_URL = "https://coding.dashscope.aliyuncs.com/v1"
                    Write-Host ""
                    if ($script:AGENTTEAMS_UPGRADE -and $script:config.DEFAULT_MODEL) {
                        $codingModelInput = Read-Host "$(Get-Msg 'llm.qwen.model_prompt') [${script:config.DEFAULT_MODEL}]"
                    } else {
                        $codingModelInput = Read-Host (Get-Msg "llm.qwen.model_prompt")
                    }
                    if ($codingModelInput -eq "b") { $script:StepResult = "back"; return }
                    $script:config.DEFAULT_MODEL = if ($codingModelInput) { $codingModelInput } elseif ($script:config.DEFAULT_MODEL) { $script:config.DEFAULT_MODEL } else { "qwen3.6-plus" }
                    Write-Log (Get-Msg "llm.provider.selected_codingplan_legacy")
                    Request-CustomModelParams $script:config.DEFAULT_MODEL
                    if ($script:StepResult -eq "back") { return }
                } else {
                    Write-Error (Get-Msg "llm.alibaba.model.invalid" -f $modelChoice)
                }
            }

            Write-Log (Get-Msg "llm.model.label" -f $script:config.DEFAULT_MODEL)
            Write-Log ""
            if ($alibabaAccess -eq "bailian") {
                Write-Log (Get-Msg "llm.apikey_hint_bailian")
                Write-Log (Get-Msg "llm.apikey_url_bailian")
            } elseif ($script:AGENTTEAMS_LANGUAGE -eq "en") {
                Write-Log (Get-Msg "llm.apikey_hint_qwencloud")
                Write-Log (Get-Msg "llm.apikey_url_qwencloud")
            } elseif ($alibabaAccess -eq "codingplan_legacy") {
                Write-Log (Get-Msg "llm.apikey_hint_codingplan")
                Write-Log (Get-Msg "llm.apikey_url_codingplan")
            } else {
                Write-Log (Get-Msg "llm.apikey_hint_tokenplan")
                Write-Log (Get-Msg "llm.apikey_url_tokenplan")
            }
            Write-Log ""
            $script:config.LLM_API_KEY = Read-Prompt -VarName "AGENTTEAMS_LLM_API_KEY" -PromptText (Get-Msg "llm.apikey_prompt") -Secret
            if ($script:StepResult -eq "back") { return }
            if ($alibabaAccess -eq "bailian") {
                Test-LlmConnectivity -BaseUrl "https://dashscope.aliyuncs.com/compatible-mode/v1" -ApiKey $script:config.LLM_API_KEY -Model $script:config.DEFAULT_MODEL
            } elseif ($alibabaAccess -eq "codingplan_legacy") {
                Test-LlmConnectivity -BaseUrl "https://coding.dashscope.aliyuncs.com/v1" -ApiKey $script:config.LLM_API_KEY -Model $script:config.DEFAULT_MODEL -Hint (Get-Msg "llm.openai.test.fail.codingplan_legacy")
            } elseif ($script:AGENTTEAMS_LANGUAGE -eq "en") {
                Test-LlmConnectivity -BaseUrl $script:config.OPENAI_BASE_URL -ApiKey $script:config.LLM_API_KEY -Model $script:config.DEFAULT_MODEL -Hint (Get-Msg "llm.openai.test.fail.codingplan")
            } else {
                Test-LlmConnectivity -BaseUrl $script:config.OPENAI_BASE_URL -ApiKey $script:config.LLM_API_KEY -Model $script:config.DEFAULT_MODEL -Hint (Get-Msg "llm.openai.test.fail.tokenplan")
            }
            if ($script:StepResult -eq "back") { return }
        }
        "^(2|openai-compat)$" {
            $script:config.LLM_PROVIDER = "openai-compat"
            Write-Log (Get-Msg "llm.provider.selected_openai" -f $script:config.LLM_PROVIDER)
            Write-Host ""
            if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_UPGRADE_KEEP_ALL -eq "1") {
                Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "llm.openai.base_url_prompt"), $script:config.OPENAI_BASE_URL)
            } else {
                $currentUrl = $script:config.OPENAI_BASE_URL
                # Use base prompt without embedded default when showing current value
                if ($currentUrl) {
                    $urlInput = Read-Host "$(Get-Msg 'llm.openai.base_url_prompt') [$currentUrl]"
                } else {
                    $urlInput = Read-Host "$(Get-Msg 'llm.openai.base_url_prompt') [https://api.openai.com/v1]"
                }
                if ($urlInput -eq "b") { $script:StepResult = "back"; return }
                if ($urlInput) {
                    $script:config.OPENAI_BASE_URL = $urlInput
                } elseif ($currentUrl) {
                    $script:config.OPENAI_BASE_URL = $currentUrl
                } else {
                    $script:config.OPENAI_BASE_URL = "https://api.openai.com/v1"
                }
            }
            if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_UPGRADE_KEEP_ALL -eq "1") {
                Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "llm.openai.model_prompt"), $script:config.DEFAULT_MODEL)
            } else {
                $currentModel = $script:config.DEFAULT_MODEL
                if ($currentModel) {
                    $modelInput = Read-Host "$(Get-Msg 'llm.openai.model_prompt') [${currentModel}]"
                } else {
                    $modelInput = Read-Host (Get-Msg 'llm.openai.model_prompt')
                }
                if ($modelInput -eq "b") { $script:StepResult = "back"; return }
                if ($modelInput) {
                    $script:config.DEFAULT_MODEL = $modelInput
                } elseif ($currentModel) {
                    $script:config.DEFAULT_MODEL = $currentModel
                } else {
                    $script:config.DEFAULT_MODEL = "gpt-5.4"
                }
            }
            Write-Log (Get-Msg "llm.openai.base_url_label" -f $script:config.OPENAI_BASE_URL)
            Write-Log (Get-Msg "llm.model.label" -f $script:config.DEFAULT_MODEL)
            Request-CustomModelParams $script:config.DEFAULT_MODEL
            if ($script:StepResult -eq "back") { return }
            Write-Log ""
            $script:config.LLM_API_KEY = Read-Prompt -VarName "AGENTTEAMS_LLM_API_KEY" -PromptText (Get-Msg "llm.apikey_prompt") -Secret
            if ($script:StepResult -eq "back") { return }
            Test-LlmConnectivity -BaseUrl $script:config.OPENAI_BASE_URL -ApiKey $script:config.LLM_API_KEY -Model $script:config.DEFAULT_MODEL
            if ($script:StepResult -eq "back") { return }
        }
        default {
            Write-Error (Get-Msg "llm.provider.invalid" -f $providerChoice)
        }
    }

    # Skip to embedding if Keep-All mode handled LLM params
    if ($skipToEmbedding) {
        # Skip embedding selection, use loaded value (already in $script:config.EMBEDDING_MODEL)
        if ($script:config.EMBEDDING_MODEL) {
            Write-Log (Get-Msg "llm.embedding.title")
            Write-Log (Get-Msg "llm.model.label" -f $script:config.EMBEDDING_MODEL)
            Write-Log ""
        }
        return
    }

    # --- Embedding model (optional, auto-tested) ---
    Write-Host ""
    Write-Log (Get-Msg "llm.embedding.title")
    Write-Log (Get-Msg "llm.embedding.hint")
    Write-Host ""
    Write-Host (Get-Msg "llm.embedding.option.default")
    Write-Host (Get-Msg "llm.embedding.option.custom")
    Write-Host (Get-Msg "llm.embedding.option.disable")
    Write-Host ""
    $embChoice = Read-Host "$(Get-Msg 'llm.embedding.select') [1]"
    $embChoice = if ($embChoice) { $embChoice } else { "1" }
    if ($embChoice -eq "b") { $script:StepResult = "back"; return }

    switch ($embChoice) {
        "1" {
            $script:config.EMBEDDING_MODEL = "text-embedding-v4"
        }
        "2" {
            if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_UPGRADE_KEEP_ALL -eq "1") {
                Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "llm.embedding.custom_prompt"), $script:config.EMBEDDING_MODEL)
            } else {
                $currentEmb = $script:config.EMBEDDING_MODEL
                $embCustom = Read-Host (Get-Msg "llm.embedding.custom_prompt")
                if ($embCustom -eq "b") { $script:StepResult = "back"; return }
                if ($embCustom) {
                    $script:config.EMBEDDING_MODEL = $embCustom
                } else {
                    $script:config.EMBEDDING_MODEL = $currentEmb
                    if (-not $script:config.EMBEDDING_MODEL) {
                        Write-Log (Get-Msg "llm.embedding.disabled")
                    }
                }
            }
        }
        "3" {
            $script:config.EMBEDDING_MODEL = ""
            Write-Log (Get-Msg "llm.embedding.disabled")
        }
        default {
            $script:config.EMBEDDING_MODEL = "text-embedding-v4"
        }
    }

    if ($script:config.EMBEDDING_MODEL) {
        # Qwen provider uses dashscope directly; others use OPENAI_BASE_URL
        $embBaseUrl = $script:config.OPENAI_BASE_URL
        if ($script:config.LLM_PROVIDER -eq "qwen") {
            $embBaseUrl = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
        $embResult = Test-EmbeddingConnectivity -BaseUrl $embBaseUrl -ApiKey $script:config.LLM_API_KEY -Model $script:config.EMBEDDING_MODEL
        if (-not $embResult) {
            $script:config.EMBEDDING_MODEL = ""
            Write-Log (Get-Msg "llm.embedding.auto_disabled")
        }
    }

    Write-Log ""
}

function Step-Admin {
    Write-Log (Get-Msg "admin.title")
    while ($true) {
        $script:config.ADMIN_USER = Read-Prompt -VarName "AGENTTEAMS_ADMIN_USER" -PromptText (Get-Msg "admin.username_prompt") -Default "admin"
        if ($script:StepResult -eq "back") { return }
        $script:config.ADMIN_USER = $script:config.ADMIN_USER.ToLowerInvariant()
        if ($script:config.ADMIN_USER.Length -ge 3) {
            break
        }
        if ($script:AGENTTEAMS_NON_INTERACTIVE) {
            Write-Error (Get-Msg "admin.username_too_short" -f $script:config.ADMIN_USER.Length)
        }
        Write-Host "$($script:ESC)[31m[AgentTeams ERROR]$($script:ESC)[0m $(Get-Msg "admin.username_too_short" -f $script:config.ADMIN_USER.Length)"
        [Environment]::SetEnvironmentVariable("AGENTTEAMS_ADMIN_USER", $null, "Process")
    }

    # Pre-set via env var: validate; non-interactive fails fast,
    # interactive warns and falls through to the retry prompt.
    if ($env:AGENTTEAMS_ADMIN_PASSWORD) {
        $script:config.ADMIN_PASSWORD = $env:AGENTTEAMS_ADMIN_PASSWORD
        Write-Log (Get-Msg "prompt.preset" -f (Get-Msg "admin.password_prompt"))
        if ($script:config.ADMIN_PASSWORD.Length -ge 8) {
            Write-Log ""
            return
        }
        if ($script:AGENTTEAMS_NON_INTERACTIVE) {
            Write-Error (Get-Msg "admin.password_too_short" -f $script:config.ADMIN_PASSWORD.Length)
        }
        Write-Host "$($script:ESC)[31m[AgentTeams ERROR]$($script:ESC)[0m $(Get-Msg "admin.password_too_short" -f $script:config.ADMIN_PASSWORD.Length)"
        [Environment]::SetEnvironmentVariable("AGENTTEAMS_ADMIN_PASSWORD", $null, "Process")
    }

    while ($true) {
        [Environment]::SetEnvironmentVariable("AGENTTEAMS_ADMIN_PASSWORD", $null, "Process")
        $script:config.ADMIN_PASSWORD = Read-Prompt -VarName "AGENTTEAMS_ADMIN_PASSWORD" -PromptText (Get-Msg "admin.password_prompt") -Secret -Optional
        if ($script:StepResult -eq "back") { return }
        if (-not $script:config.ADMIN_PASSWORD) {
            $randomSuffix = (New-RandomKey).Substring(0, 12)
            $script:config.ADMIN_PASSWORD = "admin$randomSuffix"
            Write-Log (Get-Msg "admin.password_generated")
            break
        }
        if ($script:config.ADMIN_PASSWORD.Length -ge 8) {
            break
        }
        Write-Host "$($script:ESC)[31m[AgentTeams ERROR]$($script:ESC)[0m $(Get-Msg "admin.password_too_short" -f $script:config.ADMIN_PASSWORD.Length)"
    }

    Write-Log ""
}

function Step-Network {
    Write-Log (Get-Msg "port.local_only.title")
    Write-Host ""
    Write-Host "  1) $(Get-Msg 'port.local_only.hint_yes')"
    Write-Host "  2) $(Get-Msg 'port.local_only.hint_no')"
    Write-Host ""

    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $localOnly = if ($env:AGENTTEAMS_LOCAL_ONLY) { $env:AGENTTEAMS_LOCAL_ONLY } else { "1" }
    } elseif ($null -ne $env:AGENTTEAMS_LOCAL_ONLY) {
        $localOnly = $env:AGENTTEAMS_LOCAL_ONLY
    } else {
        $localChoice = Read-Host "$(Get-Msg 'port.local_only.choice')"
        if ($localChoice -eq "b") { $script:StepResult = "back"; return }
        if (-not $localChoice) { $localChoice = "1" }
        $localOnly = if ($localChoice -match '^(2|n|N|no|NO)$') { "0" } else { "1" }
    }
    $script:config.LOCAL_ONLY = $localOnly

    if ($localOnly -eq "1") {
        Write-Log (Get-Msg "port.local_only.selected_local")
    } else {
        Write-Log (Get-Msg "port.local_only.selected_external")
        Write-Host ""
        Write-Host (Get-Msg "port.local_only.https_hint") -ForegroundColor Yellow
    }
    Write-Log ""
}

function Step-Ports {
    Write-Log (Get-Msg "port.title")
    $script:config.PORT_GATEWAY = Read-Prompt -VarName "AGENTTEAMS_PORT_GATEWAY" -PromptText (Get-Msg "port.gateway_prompt") -Default "18080"
    if ($script:StepResult -eq "back") { return }
    $script:config.PORT_CONSOLE = Read-Prompt -VarName "AGENTTEAMS_PORT_CONSOLE" -PromptText (Get-Msg "port.console_prompt") -Default "18001"
    if ($script:StepResult -eq "back") { return }
    $script:config.PORT_ELEMENT_WEB = Read-Prompt -VarName "AGENTTEAMS_PORT_ELEMENT_WEB" -PromptText (Get-Msg "port.element_prompt") -Default "18088"
    if ($script:StepResult -eq "back") { return }
    $script:config.PORT_MANAGER_CONSOLE = Read-Prompt -VarName "AGENTTEAMS_PORT_MANAGER_CONSOLE" -PromptText (Get-Msg "port.manager_console_prompt") -Default "18888"
    if ($script:StepResult -eq "back") { return }
    Write-Log ""
}

function Step-Domains {
    Write-Log (Get-Msg "domain.title")
    Write-Log (Get-Msg "domain.hint")
    $script:config.MATRIX_DOMAIN = Read-Prompt -VarName "AGENTTEAMS_MATRIX_DOMAIN" -PromptText (Get-Msg "domain.matrix_prompt") -Default "matrix-local.agentteams.io:$($script:config.PORT_GATEWAY)"
    if ($script:StepResult -eq "back") { return }
    $script:config.MATRIX_CLIENT_DOMAIN = Read-Prompt -VarName "AGENTTEAMS_MATRIX_CLIENT_DOMAIN" -PromptText (Get-Msg "domain.element_prompt") -Default "matrix-client-local.agentteams.io"
    if ($script:StepResult -eq "back") { return }
    $script:config.AI_GATEWAY_DOMAIN = Read-Prompt -VarName "AGENTTEAMS_AI_GATEWAY_DOMAIN" -PromptText (Get-Msg "domain.gateway_prompt") -Default "aigw-local.agentteams.io"
    if ($script:StepResult -eq "back") { return }
    $script:config.FS_DOMAIN = Read-Prompt -VarName "AGENTTEAMS_FS_DOMAIN" -PromptText (Get-Msg "domain.fs_prompt") -Default "fs-local.agentteams.io"
    if ($script:StepResult -eq "back") { return }
    $script:config.CONSOLE_DOMAIN = Read-Prompt -VarName "AGENTTEAMS_CONSOLE_DOMAIN" -PromptText (Get-Msg "domain.console_prompt") -Default "console-local.agentteams.io"
    if ($script:StepResult -eq "back") { return }
    Write-Log ""
}

function Step-Github {
    Write-Log (Get-Msg "github.title")
    $script:config.GITHUB_TOKEN = Read-Prompt -VarName "AGENTTEAMS_GITHUB_TOKEN" -PromptText (Get-Msg "github.token_prompt") -Secret -Optional
}

function Step-Skills {
    Write-Log ""
    Write-Log (Get-Msg "skills.title")
    $script:config.SKILLS_API_URL = Read-Prompt -VarName "AGENTTEAMS_SKILLS_API_URL" -PromptText (Get-Msg "skills.url_prompt") -Optional
    if ($script:StepResult -eq "back") { return }
    Write-Log ""
}

function Step-Volume {
    Write-Log (Get-Msg "data.title")
    # ── Non-interactive guard (deep defense) ──────────────────────────
    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.DATA_DIR = if ($env:AGENTTEAMS_DATA_DIR) { $env:AGENTTEAMS_DATA_DIR } else { "$($script:DEFAULT_DATA_VOLUME)" }
        Write-Log "  $(Get-Msg 'data.volume_using' -f $script:config.DATA_DIR) (non-interactive, skipped)"
        return
    }
    # ─────────────────────────────────────────────────────────────────
    $dataDirInput = Read-Host (Get-Msg "data.volume_prompt")
    if ($dataDirInput -eq "b") { $script:StepResult = "back"; return }
    $script:config.DATA_DIR = if ($dataDirInput) { $dataDirInput } else { "$($script:DEFAULT_DATA_VOLUME)" }
    Write-Log (Get-Msg "data.volume_using" -f $script:config.DATA_DIR)
}

function Step-Workspace {
    Write-Log (Get-Msg "workspace.title")
    # ── Non-interactive guard (deep defense) ──────────────────────────
    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.WORKSPACE_DIR = if ($env:AGENTTEAMS_WORKSPACE_DIR) { $env:AGENTTEAMS_WORKSPACE_DIR } else { "$env:USERPROFILE\$($script:MANAGER_CONTAINER)" }
        if (-not (Test-Path $script:config.WORKSPACE_DIR)) {
            New-Item -ItemType Directory -Path $script:config.WORKSPACE_DIR -Force | Out-Null
        }
        Write-Log "  $(Get-Msg 'workspace.dir_label' -f $script:config.WORKSPACE_DIR) (non-interactive, skipped)"
        return
    }
    # ─────────────────────────────────────────────────────────────────
    $defaultWorkspace = "$env:USERPROFILE\$($script:MANAGER_CONTAINER)"
    if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_UPGRADE_KEEP_ALL -eq "1") {
        Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "workspace.dir_prompt" -f $defaultWorkspace), $script:config.WORKSPACE_DIR)
        $wsInput = if ($script:config.WORKSPACE_DIR) { $script:config.WORKSPACE_DIR } else { $defaultWorkspace }
    } else {
        $currentWs = $script:config.WORKSPACE_DIR
        $wsInput = Read-Host (Get-Msg "workspace.dir_prompt" -f $defaultWorkspace)
        if ($wsInput -eq "b") { $script:StepResult = "back"; return }
        $wsInput = if ($wsInput) { $wsInput } else { if ($currentWs) { $currentWs } else { $defaultWorkspace } }
    }
    $script:config.WORKSPACE_DIR = $wsInput
    if (-not (Test-Path $script:config.WORKSPACE_DIR)) {
        New-Item -ItemType Directory -Path $script:config.WORKSPACE_DIR -Force | Out-Null
    }
    Write-Log (Get-Msg "workspace.dir_label" -f $script:config.WORKSPACE_DIR)
}

function Step-Runtime {
    $deepSeekHarnessAvailable = Test-DeepSeekHarnessAvailable
    Write-Log (Get-Msg "worker_runtime.title")
    Write-Host ""
    Write-Host "  1) $(Get-Msg 'worker_runtime.qwenpaw')"
    Write-Host "  2) $(Get-Msg 'worker_runtime.hermes')"
    if ($deepSeekHarnessAvailable) { Write-Host "  3) $(Get-Msg 'worker_runtime.deepseek_harness')" }
    Write-Host "  4) $(Get-Msg 'worker_runtime.openclaw')"
    Write-Host "  5) $(Get-Msg 'worker_runtime.codex')"
    Write-Host ""

    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.DEFAULT_WORKER_RUNTIME = if ($env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME) { $env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME } else { "codex" }
    } elseif ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME) {
        Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "worker_runtime.title_short"), $env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME)
        if ($env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME -eq "copaw") {
            Write-Log ("      " + (Get-Msg "worker_runtime.copaw"))
        }
        $rtChoice = Read-Host (Get-Msg $(if ($deepSeekHarnessAvailable) { "worker_runtime.choice_dsh" } else { "worker_runtime.choice" }))
        if ($rtChoice -eq "b") { $script:StepResult = "back"; return }
        if ($rtChoice) {
            $script:config.DEFAULT_WORKER_RUNTIME = switch ($rtChoice) {
                "5" { "codex" }
                "4" { "openclaw" }
                "2" { "hermes" }
                "3" { if ($deepSeekHarnessAvailable) { "deepseek-harness" } else { "codex" } }
                default { "qwenpaw" }
            }
        } else {
            $script:config.DEFAULT_WORKER_RUNTIME = $env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME
        }
    } elseif ($env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME) {
        $script:config.DEFAULT_WORKER_RUNTIME = $env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME
    } else {
        $rtChoice = Read-Host (Get-Msg $(if ($deepSeekHarnessAvailable) { "worker_runtime.choice_dsh" } else { "worker_runtime.choice" }))
        if ($rtChoice -eq "b") { $script:StepResult = "back"; return }
        $rtChoice = if ($rtChoice) { $rtChoice } else { "5" }
        $script:config.DEFAULT_WORKER_RUNTIME = switch ($rtChoice) {
            "5" { "codex" }
            "4" { "openclaw" }
            "2" { "hermes" }
            "3" { if ($deepSeekHarnessAvailable) { "deepseek-harness" } else { "codex" } }
            default { "qwenpaw" }
        }
    }
    if ($script:config.DEFAULT_WORKER_RUNTIME -eq "deepseek-harness" -and -not $deepSeekHarnessAvailable) {
        Write-Error (Get-Msg "worker_runtime.deepseek_unavailable")
    }
    Write-Log (Get-Msg "worker_runtime.selected" -f $script:config.DEFAULT_WORKER_RUNTIME)
}

function Step-ManagerRuntime {
    Write-Log (Get-Msg "manager_runtime.title")
    Write-Host ""
    Write-Host "  1) $(Get-Msg 'manager_runtime.qwenpaw')"
    Write-Host "  2) $(Get-Msg 'manager_runtime.hermes')"
    Write-Host "  3) $(Get-Msg 'manager_runtime.deepseek_harness')"
    Write-Host "  4) $(Get-Msg 'manager_runtime.codex')"
    Write-Host "  5) $(Get-Msg 'manager_runtime.openclaw')"
    Write-Host ""

    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.MANAGER_RUNTIME = if ($env:AGENTTEAMS_MANAGER_RUNTIME) { $env:AGENTTEAMS_MANAGER_RUNTIME } else { "qwenpaw" }
    } elseif ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_MANAGER_RUNTIME) {
        Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "manager_runtime.title_short"), $env:AGENTTEAMS_MANAGER_RUNTIME)
        if ($env:AGENTTEAMS_MANAGER_RUNTIME -eq "copaw") {
            Write-Log ("      " + (Get-Msg "manager_runtime.copaw"))
        }
        $mrChoice = Read-Host (Get-Msg "manager_runtime.choice")
        if ($mrChoice -eq "b") { $script:StepResult = "back"; return }
        if ($mrChoice) {
            $script:config.MANAGER_RUNTIME = switch ($mrChoice) {
                "5" { "openclaw" }
                "2" { "hermes" }
                "3" { "deepseek-harness" }
                "4" { "codex" }
                default { "qwenpaw" }
            }
        } else {
            $script:config.MANAGER_RUNTIME = $env:AGENTTEAMS_MANAGER_RUNTIME
        }
    } elseif ($env:AGENTTEAMS_MANAGER_RUNTIME) {
        $script:config.MANAGER_RUNTIME = $env:AGENTTEAMS_MANAGER_RUNTIME
    } else {
        $mrChoice = Read-Host (Get-Msg "manager_runtime.choice")
        if ($mrChoice -eq "b") { $script:StepResult = "back"; return }
        $mrChoice = if ($mrChoice) { $mrChoice } else { "1" }
        $script:config.MANAGER_RUNTIME = switch ($mrChoice) {
            "5" { "openclaw" }
            "2" { "hermes" }
            "3" { "deepseek-harness" }
            "4" { "codex" }
            default { "qwenpaw" }
        }
    }
    Write-Log (Get-Msg "manager_runtime.selected" -f $script:config.MANAGER_RUNTIME)
}

function Step-E2ee {
    Write-Host ""
    Write-Log (Get-Msg "matrix_e2ee.title")
    # ── Non-interactive guard (deep defense) ──────────────────────────
    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.MATRIX_E2EE = if ($env:AGENTTEAMS_MATRIX_E2EE) { $env:AGENTTEAMS_MATRIX_E2EE } else { "0" }
        Write-Log "  $(Get-Msg 'matrix_e2ee.title_short') = $($script:config.MATRIX_E2EE) (non-interactive, skipped)"
        return
    }
    # ─────────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "  $(Get-Msg 'matrix_e2ee.desc')"
    Write-Host ""
    Write-Host "  1) $(Get-Msg 'matrix_e2ee.disable')"
    Write-Host "  2) $(Get-Msg 'matrix_e2ee.enable')"
    Write-Host ""

    if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_MATRIX_E2EE) {
        $e2eeDisplay = if ($env:AGENTTEAMS_MATRIX_E2EE -eq "1") { Get-Msg "matrix_e2ee.val_enabled" } else { Get-Msg "matrix_e2ee.val_disabled" }
        Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "matrix_e2ee.title_short"), $e2eeDisplay)
        $e2eeChoice = Read-Host (Get-Msg "matrix_e2ee.choice")
        if ($e2eeChoice -eq "b") { $script:StepResult = "back"; return }
        if ($e2eeChoice) {
            $script:config.MATRIX_E2EE = if ($e2eeChoice -eq "2") { "1" } else { "0" }
        } else {
            $script:config.MATRIX_E2EE = $env:AGENTTEAMS_MATRIX_E2EE
        }
    } elseif (-not $env:AGENTTEAMS_MATRIX_E2EE) {
        $e2eeChoice = Read-Host (Get-Msg "matrix_e2ee.choice")
        if ($e2eeChoice -eq "b") { $script:StepResult = "back"; return }
        $e2eeChoice = if ($e2eeChoice) { $e2eeChoice } else { "1" }
        $script:config.MATRIX_E2EE = if ($e2eeChoice -eq "2") { "1" } else { "0" }
    } else {
        $script:config.MATRIX_E2EE = $env:AGENTTEAMS_MATRIX_E2EE
    }

    if ($script:config.MATRIX_E2EE -eq "1") {
        Write-Log (Get-Msg "matrix_e2ee.selected_enabled")
    } else {
        Write-Log (Get-Msg "matrix_e2ee.selected_disabled")
    }
}

function Step-DockerProxy {
    if (-not $script:AGENTTEAMS_MOUNT_SOCKET) {
        $script:config.DOCKER_PROXY = "0"
        return
    }

    # ── Non-interactive guard (deep defense) ──────────────────────────
    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.DOCKER_PROXY = if ($env:AGENTTEAMS_DOCKER_PROXY) { $env:AGENTTEAMS_DOCKER_PROXY } else { "0" }
        Write-Log "  $(Get-Msg 'docker_proxy.title_short') = $($script:config.DOCKER_PROXY) (non-interactive, skipped)"
        return
    }
    # ─────────────────────────────────────────────────────────────────

    Write-Host ""
    Write-Log (Get-Msg "docker_proxy.title")
    Write-Host ""
    Write-Host "  $(Get-Msg 'docker_proxy.desc')"
    Write-Host ""
    Write-Host "  1) $(Get-Msg 'docker_proxy.enable')"
    Write-Host "  2) $(Get-Msg 'docker_proxy.disable')"
    Write-Host ""

    if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_DOCKER_PROXY) {
        $proxyDisplay = if ($env:AGENTTEAMS_DOCKER_PROXY -eq "1") { Get-Msg "docker_proxy.val_enabled" } else { Get-Msg "docker_proxy.val_disabled" }
        Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "docker_proxy.title_short"), $proxyDisplay)
        $proxyChoice = Read-Host (Get-Msg "docker_proxy.choice")
        if ($proxyChoice -eq "b") { $script:StepResult = "back"; return }
        if ($proxyChoice) {
            $script:config.DOCKER_PROXY = if ($proxyChoice -eq "2") { "0" } else { "1" }
        } else {
            $script:config.DOCKER_PROXY = $env:AGENTTEAMS_DOCKER_PROXY
        }
    } elseif (-not $env:AGENTTEAMS_DOCKER_PROXY) {
        $proxyChoice = Read-Host (Get-Msg "docker_proxy.choice")
        if ($proxyChoice -eq "b") { $script:StepResult = "back"; return }
        $proxyChoice = if ($proxyChoice) { $proxyChoice } else { "1" }
        $script:config.DOCKER_PROXY = if ($proxyChoice -eq "2") { "0" } else { "1" }
    } else {
        $script:config.DOCKER_PROXY = $env:AGENTTEAMS_DOCKER_PROXY
    }

    if ($script:config.DOCKER_PROXY -eq "1") {
        Write-Log (Get-Msg "docker_proxy.selected_enabled")

        # Prompt for additional allowed image sources
        Write-Host ""
        Write-Host "  $(Get-Msg 'docker_proxy.registries_desc')"
        Write-Host ""
        if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_PROXY_ALLOWED_REGISTRIES) {
            Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "docker_proxy.registries_label"), $env:AGENTTEAMS_PROXY_ALLOWED_REGISTRIES)
            $regInput = Read-Host (Get-Msg "docker_proxy.registries_prompt")
            if ($regInput -eq "b") { $script:StepResult = "back"; return }
            $script:config.PROXY_ALLOWED_REGISTRIES = if ($regInput) { $regInput } else { $env:AGENTTEAMS_PROXY_ALLOWED_REGISTRIES }
        } elseif (-not $env:AGENTTEAMS_PROXY_ALLOWED_REGISTRIES) {
            $regInput = Read-Host (Get-Msg "docker_proxy.registries_prompt")
            if ($regInput -eq "b") { $script:StepResult = "back"; return }
            $script:config.PROXY_ALLOWED_REGISTRIES = if ($regInput) { $regInput } else { "" }
        } else {
            $script:config.PROXY_ALLOWED_REGISTRIES = $env:AGENTTEAMS_PROXY_ALLOWED_REGISTRIES
        }
    } else {
        Write-Log (Get-Msg "docker_proxy.selected_disabled")
    }
}

function Step-Idle {
    # ── Non-interactive guard (deep defense) ──────────────────────────
    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.WORKER_IDLE_TIMEOUT = if ($env:AGENTTEAMS_WORKER_IDLE_TIMEOUT) { $env:AGENTTEAMS_WORKER_IDLE_TIMEOUT } else { "720" }
        Write-Log "  $(Get-Msg 'idle_timeout.label') = $($script:config.WORKER_IDLE_TIMEOUT) (non-interactive, skipped)"
        return
    }
    # ─────────────────────────────────────────────────────────────────
    if ($script:AGENTTEAMS_UPGRADE -and $env:AGENTTEAMS_WORKER_IDLE_TIMEOUT) {
        Write-Log (Get-Msg "prompt.upgrade_keep" -f (Get-Msg "idle_timeout.label"), $env:AGENTTEAMS_WORKER_IDLE_TIMEOUT)
        $idleInput = Read-Host (Get-Msg "idle_timeout.prompt")
        if ($idleInput -eq "b") { $script:StepResult = "back"; return }
        $script:config.WORKER_IDLE_TIMEOUT = if ($idleInput) { $idleInput } else { $env:AGENTTEAMS_WORKER_IDLE_TIMEOUT }
    } elseif (-not $env:AGENTTEAMS_WORKER_IDLE_TIMEOUT) {
        $idleInput = Read-Host (Get-Msg "idle_timeout.prompt")
        if ($idleInput -eq "b") { $script:StepResult = "back"; return }
        $script:config.WORKER_IDLE_TIMEOUT = if ($idleInput) { $idleInput } else { "720" }
    } else {
        $script:config.WORKER_IDLE_TIMEOUT = $env:AGENTTEAMS_WORKER_IDLE_TIMEOUT
    }
    Write-Log (Get-Msg "idle_timeout.selected" -f $script:config.WORKER_IDLE_TIMEOUT)
    Write-Log ""
}

function Step-Hostshare {
    # ── Non-interactive guard (deep defense) ──────────────────────────
    if ($script:AGENTTEAMS_NON_INTERACTIVE) {
        $script:config.HOST_SHARE_DIR = if ($env:AGENTTEAMS_HOST_SHARE_DIR) { $env:AGENTTEAMS_HOST_SHARE_DIR } else { $env:USERPROFILE }
        Write-Log "  $(Get-Msg 'host_share.label') = $($script:config.HOST_SHARE_DIR) (non-interactive, skipped)"
        return
    }
    # ─────────────────────────────────────────────────────────────────
    $currentShare = $script:config.HOST_SHARE_DIR
    if ($currentShare) {
        $shareInput = Read-Host "$(Get-Msg 'host_share.prompt' -f $env:USERPROFILE) [${currentShare}]"
    } else {
        $shareInput = Read-Host (Get-Msg 'host_share.prompt' -f $env:USERPROFILE)
    }
    if ($shareInput -eq "b") { $script:StepResult = "back"; return }
    $script:config.HOST_SHARE_DIR = if ($shareInput) { $shareInput } else { if ($currentShare) { $currentShare } else { $env:USERPROFILE } }
}

# ============================================================
# Manager Installation
# ============================================================

function Install-Manager {
    # Detect timezone
    $script:AGENTTEAMS_TIMEZONE = Get-AgentTeamsTimeZone

    # Language priority: env var > existing env file > timezone detection
    if ($env:AGENTTEAMS_LANGUAGE) {
        $script:AGENTTEAMS_LANGUAGE = $env:AGENTTEAMS_LANGUAGE
    } else {
        # Check existing env file for saved language preference (upgrade scenario)
        $_envFile = $script:AGENTTEAMS_ENV_FILE
        # Migrate from legacy location (current directory) if needed
        $legacyEnvFile = ".\$($script:MANAGER_CONTAINER).env"
        if (-not (Test-Path $_envFile) -and (Test-Path $legacyEnvFile)) {
            Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value "Migrating $legacyEnvFile to $_envFile"
            Move-Item $legacyEnvFile $_envFile -ErrorAction SilentlyContinue
        }
        if (Test-Path $_envFile) {
            $_savedLang = (Get-Content $_envFile | Select-String "^AGENTTEAMS_LANGUAGE=" | ForEach-Object {
                $_.Line -replace '^AGENTTEAMS_LANGUAGE=', ''
            } | Select-Object -First 1)
            if ($_savedLang) {
                $script:AGENTTEAMS_LANGUAGE = $_savedLang
            }
        }
        # Fall back to timezone-based detection
        if (-not $script:AGENTTEAMS_LANGUAGE) {
            $script:AGENTTEAMS_LANGUAGE = Get-AgentTeamsLanguage -Timezone $script:AGENTTEAMS_TIMEZONE
        }
    }
    $env:AGENTTEAMS_LANGUAGE = $script:AGENTTEAMS_LANGUAGE
    Write-Log (Get-Msg "install.title")

    # "latest" is mutable. Refresh the stable release used by runtime feature
    # gates so a newly released Controller is not hidden behind a stale constant.
    Update-AgentTeamsKnownStableVersion

    # Detect registry
    $script:AGENTTEAMS_REGISTRY = Get-Registry -Timezone $script:AGENTTEAMS_TIMEZONE

    # Check the container runtime before resolving images. Resolve-EmbeddedImage
    # performs docker pull for remote tags, so these actionable errors must win
    # over a misleading "embedded image unavailable" failure.
    Ensure-ContainerRuntime

    # Initialize shared config hashtable
    $script:config = @{}
    $config = $script:config  # local alias so post-machine code can use $config

    # A missing env file must never turn an existing data volume into a fresh install.
    if (-not (Test-Path $script:AGENTTEAMS_ENV_FILE)) { Recover-ExistingInstall }

    # ── State machine ─────────────────────────────────────────────────────────
    $_steps = @("Step-Lang", "Step-Mode", "Step-Existing", "Step-Llm", "Step-ManagerRuntime", "Step-Runtime", "Step-Admin",
                "Step-Network", "Step-Ports", "Step-Domains", "Step-Github", "Step-Skills",
                "Step-Volume", "Step-Workspace", "Step-E2ee", "Step-DockerProxy", "Step-Idle",
                "Step-Hostshare")
    $_stepHistory = [System.Collections.Generic.List[int]]::new()
    $_stepIdx = 0
    while ($_stepIdx -lt $_steps.Count) {
        $_stepFn = $_steps[$_stepIdx]
        if (Test-ShouldSkipStep $_stepFn) {
            $_stepIdx++
            continue
        }
        if ($_stepHistory.Count -gt 0) {
            Write-Log (Get-Msg "nav.back_hint")
        }
        $script:StepResult = ""
        & $_stepFn
        if ($script:StepResult -eq "back") {
            if ($_stepHistory.Count -gt 0) {
                $_stepIdx = $_stepHistory[$_stepHistory.Count - 1]
                $_stepHistory.RemoveAt($_stepHistory.Count - 1)
                Clear-StepVars $_steps[$_stepIdx]
            }
            # else: first step, ignore 'b'
        } else {
            $_stepHistory.Add($_stepIdx)
            $_stepIdx++
        }
    }
    # ── End state machine ──────────────────────────────────────────────────────

    # Saved registry and image overrides are now available.
    $script:AGENTTEAMS_REGISTRY = Get-Registry -Timezone $script:AGENTTEAMS_TIMEZONE
    # Set image names
    $openclawVersion = $script:AGENTTEAMS_VERSION
    $openclawCoreVersion = [regex]::Match($openclawVersion, '^v?(\d+\.\d+\.\d+)')
    if ($openclawVersion -eq "latest" -or ($openclawCoreVersion.Success -and [version]$openclawCoreVersion.Groups[1].Value -gt [version]'1.2.8')) { $openclawVersion = "v1.2.8" }
    $deepseekVersion = if ($script:AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION) { $script:AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION } else { $script:AGENTTEAMS_VERSION }
    $codexVersion = if ($script:AGENTTEAMS_CODEX_WORKER_VERSION) { $script:AGENTTEAMS_CODEX_WORKER_VERSION } else { $script:AGENTTEAMS_VERSION }
    $script:MANAGER_IMAGE = if ($env:AGENTTEAMS_INSTALL_MANAGER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_MANAGER_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-manager:$($script:AGENTTEAMS_VERSION)"
    }

    $script:MANAGER_QWENPAW_IMAGE = if ($env:AGENTTEAMS_INSTALL_MANAGER_QWENPAW_IMAGE) {
        $env:AGENTTEAMS_INSTALL_MANAGER_QWENPAW_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-manager-qwenpaw:$($script:AGENTTEAMS_VERSION)"
    }

    $script:WORKER_IMAGE = if ($env:AGENTTEAMS_INSTALL_WORKER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_WORKER_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-harness-openclaw:${openclawVersion}"
    }

    # CoPaw images are no longer built; only an explicit legacy override is honored.
    $script:COPAW_WORKER_IMAGE = $env:AGENTTEAMS_INSTALL_COPAW_WORKER_IMAGE

    $script:QWENPAW_WORKER_IMAGE = if ($env:AGENTTEAMS_INSTALL_QWENPAW_WORKER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_QWENPAW_WORKER_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-harness-qwenpaw:$($script:AGENTTEAMS_VERSION)"
    }

    $script:HERMES_WORKER_IMAGE = if ($env:AGENTTEAMS_INSTALL_HERMES_WORKER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_HERMES_WORKER_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-harness-hermes:$($script:AGENTTEAMS_VERSION)"
    }

    $script:DEEPSEEK_HARNESS_WORKER_IMAGE = if ($env:AGENTTEAMS_INSTALL_DEEPSEEK_HARNESS_WORKER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_DEEPSEEK_HARNESS_WORKER_IMAGE
    } elseif (Test-DeepSeekHarnessAvailable) {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-harness-deepseek:${deepseekVersion}"
    } else {
        ""
    }

    $script:CODEX_WORKER_IMAGE = if ($env:AGENTTEAMS_INSTALL_CODEX_WORKER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_CODEX_WORKER_IMAGE
    } elseif ($env:AGENTTEAMS_CODEX_WORKER_IMAGE) {
        $env:AGENTTEAMS_CODEX_WORKER_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-harness-codex:${codexVersion}"
    }

    $script:MANAGER_COPAW_IMAGE = $env:AGENTTEAMS_INSTALL_MANAGER_COPAW_IMAGE

    $script:OPENHUMAN_WORKER_IMAGE = if ($env:AGENTTEAMS_INSTALL_OPENHUMAN_WORKER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_OPENHUMAN_WORKER_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-harness-openhuman:$($script:AGENTTEAMS_VERSION)"
    }
    $coreVersionMatch = [regex]::Match($script:AGENTTEAMS_VERSION, '^v?(\d+\.\d+\.\d+)')
    if ($coreVersionMatch.Success -and [version]$coreVersionMatch.Groups[1].Value -lt [version]'1.2.7') {
        if (-not $env:AGENTTEAMS_INSTALL_WORKER_IMAGE) { $script:WORKER_IMAGE = $script:WORKER_IMAGE.Replace('agentteams-harness-openclaw', 'agentteams-worker') }
        if (-not $env:AGENTTEAMS_INSTALL_QWENPAW_WORKER_IMAGE) { $script:QWENPAW_WORKER_IMAGE = $script:QWENPAW_WORKER_IMAGE.Replace('agentteams-harness-qwenpaw', 'agentteams-qwenpaw-worker') }
        if (-not $env:AGENTTEAMS_INSTALL_HERMES_WORKER_IMAGE) { $script:HERMES_WORKER_IMAGE = $script:HERMES_WORKER_IMAGE.Replace('agentteams-harness-hermes', 'agentteams-hermes-worker') }
        if (-not $env:AGENTTEAMS_INSTALL_OPENHUMAN_WORKER_IMAGE) { $script:OPENHUMAN_WORKER_IMAGE = $script:OPENHUMAN_WORKER_IMAGE.Replace('agentteams-harness-openhuman', 'agentteams-openhuman-worker') }
        if (-not $env:AGENTTEAMS_INSTALL_DEEPSEEK_HARNESS_WORKER_IMAGE -and -not $env:AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION -and $script:AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_VERSION -in @($null, '', 'v0.1.2', 'v1.2.7')) {
            $script:DEEPSEEK_HARNESS_WORKER_IMAGE = "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-deepseek-harness-worker:v0.1.1"
        }
    }
    if ($coreVersionMatch.Success -and [version]$coreVersionMatch.Groups[1].Value -lt [version]'1.2.7' -and -not $env:AGENTTEAMS_INSTALL_CODEX_WORKER_IMAGE -and -not $env:AGENTTEAMS_CODEX_WORKER_IMAGE -and -not $env:AGENTTEAMS_CODEX_WORKER_VERSION -and $script:AGENTTEAMS_CODEX_WORKER_VERSION -in @($null, '', 'v1.2.7')) {
        $script:CODEX_WORKER_IMAGE = "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-harness-codex:v0.1.0"
    }
    $dshVersionMatch = [regex]::Match($deepseekVersion, '^v?(\d+\.\d+\.\d+)')
    if (-not $env:AGENTTEAMS_INSTALL_DEEPSEEK_HARNESS_WORKER_IMAGE -and $dshVersionMatch.Success -and [version]$dshVersionMatch.Groups[1].Value -lt [version]'0.1.2') {
        $script:DEEPSEEK_HARNESS_WORKER_IMAGE = $script:DEEPSEEK_HARNESS_WORKER_IMAGE.Replace('agentteams-harness-deepseek', 'agentteams-deepseek-harness-worker')
    }

    $script:CONTROLLER_IMAGE = if ($env:AGENTTEAMS_INSTALL_CONTROLLER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_CONTROLLER_IMAGE
    } else {
        "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-controller:$($script:AGENTTEAMS_VERSION)"
    }

    if (-not $coreVersionMatch.Success -or [version]$coreVersionMatch.Groups[1].Value -ge [version]'1.2.7') {
        if (-not $env:AGENTTEAMS_INSTALL_MANAGER_IMAGE) { $script:MANAGER_IMAGE = $script:WORKER_IMAGE }
        if (-not $env:AGENTTEAMS_INSTALL_MANAGER_QWENPAW_IMAGE) { $script:MANAGER_QWENPAW_IMAGE = $script:QWENPAW_WORKER_IMAGE }
    }

    # Resolve embedded controller image (sets $script:EMBEDDED_IMAGE and
    # $script:AGENTTEAMS_USE_EMBEDDED). Errors out fast if no embedded image is available
    # for the requested version (mirrors the bash installer behavior).
    Resolve-EmbeddedImage

    # Post-machine defaults for any steps that were skipped
    if (-not $script:config.DATA_DIR) {
        $script:config.DATA_DIR = if ($env:AGENTTEAMS_DATA_DIR) { $env:AGENTTEAMS_DATA_DIR } else { "$($script:DEFAULT_DATA_VOLUME)" }
    }
    Write-Log (Get-Msg "data.volume_using" -f $script:config.DATA_DIR)
    if (-not $script:config.WORKSPACE_DIR) {
        $_defaultWs = "$env:USERPROFILE\$($script:MANAGER_CONTAINER)"
        $script:config.WORKSPACE_DIR = if ($env:AGENTTEAMS_WORKSPACE_DIR) { $env:AGENTTEAMS_WORKSPACE_DIR } else { $_defaultWs }
        if (-not (Test-Path $script:config.WORKSPACE_DIR)) {
            New-Item -ItemType Directory -Path $script:config.WORKSPACE_DIR -Force | Out-Null
        }
        Write-Log (Get-Msg "workspace.dir_label" -f $script:config.WORKSPACE_DIR)
    }
    if (-not $script:config.DEFAULT_WORKER_RUNTIME) {
        $script:config.DEFAULT_WORKER_RUNTIME = if ($env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME) { $env:AGENTTEAMS_DEFAULT_WORKER_RUNTIME } else { "codex" }
        Write-Log (Get-Msg "worker_runtime.selected" -f $script:config.DEFAULT_WORKER_RUNTIME)
    }
    if (-not $script:config.MATRIX_E2EE) {
        $script:config.MATRIX_E2EE = if ($env:AGENTTEAMS_MATRIX_E2EE) { $env:AGENTTEAMS_MATRIX_E2EE } else { "0" }
    }
    if (-not $script:config.WORKER_IDLE_TIMEOUT) {
        $script:config.WORKER_IDLE_TIMEOUT = if ($env:AGENTTEAMS_WORKER_IDLE_TIMEOUT) { $env:AGENTTEAMS_WORKER_IDLE_TIMEOUT } else { "720" }
    }
    if (-not $script:config.HOST_SHARE_DIR) {
        $script:config.HOST_SHARE_DIR = if ($env:AGENTTEAMS_HOST_SHARE_DIR) { $env:AGENTTEAMS_HOST_SHARE_DIR } else { $env:USERPROFILE }
    }
    if (-not $script:config.LOCAL_ONLY) {
        $script:config.LOCAL_ONLY = if ($env:AGENTTEAMS_LOCAL_ONLY) { $env:AGENTTEAMS_LOCAL_ONLY } else { "1" }
    }
    if (-not $script:config.MANAGER_RUNTIME) {
        $script:config.MANAGER_RUNTIME = if ($env:AGENTTEAMS_MANAGER_RUNTIME) { $env:AGENTTEAMS_MANAGER_RUNTIME } else { "qwenpaw" }
    }
    if (-not $script:config.PORT_GATEWAY) {
        $script:config.PORT_GATEWAY = if ($env:AGENTTEAMS_PORT_GATEWAY) { $env:AGENTTEAMS_PORT_GATEWAY } else { "18080" }
        $script:config.PORT_CONSOLE = if ($env:AGENTTEAMS_PORT_CONSOLE) { $env:AGENTTEAMS_PORT_CONSOLE } else { "18001" }
        $script:config.PORT_ELEMENT_WEB = if ($env:AGENTTEAMS_PORT_ELEMENT_WEB) { $env:AGENTTEAMS_PORT_ELEMENT_WEB } else { "18088" }
        $script:config.PORT_MANAGER_CONSOLE = if ($env:AGENTTEAMS_PORT_MANAGER_CONSOLE) { $env:AGENTTEAMS_PORT_MANAGER_CONSOLE } else { "18888" }
    }
    if (-not $script:config.MATRIX_DOMAIN) {
        $script:config.MATRIX_DOMAIN = if ($env:AGENTTEAMS_MATRIX_DOMAIN) { $env:AGENTTEAMS_MATRIX_DOMAIN } else { "matrix-local.agentteams.io:$($script:config.PORT_GATEWAY)" }
        $script:config.MATRIX_CLIENT_DOMAIN = if ($env:AGENTTEAMS_MATRIX_CLIENT_DOMAIN) { $env:AGENTTEAMS_MATRIX_CLIENT_DOMAIN } else { "matrix-client-local.agentteams.io" }
        $script:config.AI_GATEWAY_DOMAIN = if ($env:AGENTTEAMS_AI_GATEWAY_DOMAIN) { $env:AGENTTEAMS_AI_GATEWAY_DOMAIN } else { "aigw-local.agentteams.io" }
        $script:config.FS_DOMAIN = if ($env:AGENTTEAMS_FS_DOMAIN) { $env:AGENTTEAMS_FS_DOMAIN } else { "fs-local.agentteams.io" }
        $script:config.CONSOLE_DOMAIN = if ($env:AGENTTEAMS_CONSOLE_DOMAIN) { $env:AGENTTEAMS_CONSOLE_DOMAIN } else { "console-local.agentteams.io" }
    }

    Write-Log ""

    # Generate secrets
    Write-Log (Get-Msg "install.generating_secrets")
    $config.MANAGER_PASSWORD = if ($env:AGENTTEAMS_MANAGER_PASSWORD) { $env:AGENTTEAMS_MANAGER_PASSWORD } else { New-RandomKey }
    $config.REGISTRATION_TOKEN = if ($env:AGENTTEAMS_REGISTRATION_TOKEN) { $env:AGENTTEAMS_REGISTRATION_TOKEN } else { New-RandomKey }
    $config.MINIO_USER = if ($env:AGENTTEAMS_MINIO_USER) { $env:AGENTTEAMS_MINIO_USER } else { $config.ADMIN_USER }
    if ($config.MINIO_USER.Length -lt 3) {
        Write-Error (Get-Msg "admin.minio_username_too_short" -f $config.MINIO_USER.Length)
    }
    $config.MINIO_PASSWORD = if ($env:AGENTTEAMS_MINIO_PASSWORD) { $env:AGENTTEAMS_MINIO_PASSWORD } else { $config.ADMIN_PASSWORD }
    $config.MANAGER_GATEWAY_KEY = if ($env:AGENTTEAMS_MANAGER_GATEWAY_KEY) { $env:AGENTTEAMS_MANAGER_GATEWAY_KEY } else { New-RandomKey }
    $matrixAppServiceEnabled = if ($env:AGENTTEAMS_MATRIX_APPSERVICE_ENABLED) { $env:AGENTTEAMS_MATRIX_APPSERVICE_ENABLED } else { "true" }
    $config.MATRIX_APPSERVICE_ENABLED = ConvertTo-MatrixAppServiceEnabledValue $matrixAppServiceEnabled
    if ($config.MATRIX_APPSERVICE_ENABLED -ne "false" -and $config.MATRIX_APPSERVICE_ENABLED -ne "0") {
        $config.MATRIX_APPSERVICE_AS_TOKEN = if ($env:AGENTTEAMS_MATRIX_APPSERVICE_AS_TOKEN) { $env:AGENTTEAMS_MATRIX_APPSERVICE_AS_TOKEN } else { New-RandomKey }
        $config.MATRIX_APPSERVICE_HS_TOKEN = if ($env:AGENTTEAMS_MATRIX_APPSERVICE_HS_TOKEN) { $env:AGENTTEAMS_MATRIX_APPSERVICE_HS_TOKEN } else { New-RandomKey }
    }

    # Store additional config
    $config.LANGUAGE = $script:AGENTTEAMS_LANGUAGE
    $config.REGISTRY = $script:AGENTTEAMS_REGISTRY
    $config.HIGRESS_WASM_PLUGIN_REGISTRY = if ($env:AGENTTEAMS_HIGRESS_WASM_PLUGIN_REGISTRY) {
        $env:AGENTTEAMS_HIGRESS_WASM_PLUGIN_REGISTRY
    } elseif ($config.HIGRESS_WASM_PLUGIN_REGISTRY) {
        $config.HIGRESS_WASM_PLUGIN_REGISTRY
    } else {
        "higress-registry.cn-hangzhou.cr.aliyuncs.com"
    }
    $config.WORKER_IMAGE = $script:WORKER_IMAGE
    $config.COPAW_WORKER_IMAGE = $script:COPAW_WORKER_IMAGE
    $config.QWENPAW_WORKER_IMAGE = $script:QWENPAW_WORKER_IMAGE
    $config.OPENHUMAN_WORKER_IMAGE = $script:OPENHUMAN_WORKER_IMAGE
    $config.HERMES_WORKER_IMAGE = $script:HERMES_WORKER_IMAGE
    $config.DEEPSEEK_HARNESS_WORKER_IMAGE = $script:DEEPSEEK_HARNESS_WORKER_IMAGE
    $config.CODEX_WORKER_IMAGE = $script:CODEX_WORKER_IMAGE
    $config.MANAGER_QWENPAW_IMAGE = $script:MANAGER_QWENPAW_IMAGE
    $config.MANAGER_COPAW_IMAGE = $script:MANAGER_COPAW_IMAGE

    foreach ($key in @('DASHBOARD', 'DASHBOARD_VERSION', 'DASHBOARD_IMAGE', 'PORT_DASHBOARD')) {
        $value = [Environment]::GetEnvironmentVariable("AGENTTEAMS_$key", 'Process')
        if ($null -ne $value) { $config[$key] = $value }
    }
    if (-not $config.DASHBOARD) { $config.DASHBOARD = '1' }
    if (-not $config.DASHBOARD_VERSION) { $config.DASHBOARD_VERSION = 'v1.4.3' }
    if (-not $config.PORT_DASHBOARD) { $config.PORT_DASHBOARD = '13000' }
    Initialize-UnifiedEntry

    # Manager image selection (used by both embedded — passed to controller via env —
    # and legacy — used directly as `docker run` target).
    Assert-ManagerRuntime
    $managerImage = switch ($config.MANAGER_RUNTIME) {
        "qwenpaw" { $script:MANAGER_QWENPAW_IMAGE }
        # Legacy alias: route to the QwenPaw manager image unless an explicit
        # AGENTTEAMS_INSTALL_MANAGER_COPAW_IMAGE override is provided.
        "copaw" { if ($script:MANAGER_COPAW_IMAGE) { $script:MANAGER_COPAW_IMAGE } else { $script:MANAGER_QWENPAW_IMAGE } }
        "hermes" { if ($env:AGENTTEAMS_INSTALL_MANAGER_IMAGE) { $env:AGENTTEAMS_INSTALL_MANAGER_IMAGE } else { $script:HERMES_WORKER_IMAGE } }
        "deepseek-harness" { if ($env:AGENTTEAMS_INSTALL_MANAGER_IMAGE) { $env:AGENTTEAMS_INSTALL_MANAGER_IMAGE } else { $script:DEEPSEEK_HARNESS_WORKER_IMAGE } }
        "codex" { if ($env:AGENTTEAMS_INSTALL_MANAGER_IMAGE) { $env:AGENTTEAMS_INSTALL_MANAGER_IMAGE } else { $script:CODEX_WORKER_IMAGE } }
        default { $script:MANAGER_IMAGE }
    }
    $portPrefix = if ($config.LOCAL_ONLY -eq "1") { "127.0.0.1:" } else { "" }

    # Ensure agentteams-net Docker network exists. Used in both modes — the embedded
    # controller and the spawned manager/worker containers all join it and rely on
    # network aliases for *-local.agentteams.io DNS resolution.
    if ($script:AGENTTEAMS_MOUNT_SOCKET) {
        $socketAvailable = Test-DockerRunning
        if ($socketAvailable) {
            docker network inspect $($script:DOCKER_NETWORK) *>$null
            if ($LASTEXITCODE -ne 0) { docker network create $($script:DOCKER_NETWORK) *>$null }
        } else {
            Write-Log (Get-Msg "install.socket_not_found")
            if (-not $script:AGENTTEAMS_NON_INTERACTIVE) {
                Write-Host ""
                Write-Host "$($script:ESC)[33m$(Get-Msg 'install.socket_confirm.title')$($script:ESC)[0m"
                Write-Host ""
                Write-Host (Get-Msg 'install.socket_confirm.message')
                Write-Host ""
                $confirm = Read-Host (Get-Msg 'install.socket_confirm.prompt')
                if ($confirm -ne 'y' -and $confirm -ne 'Y') {
                    Write-Log (Get-Msg 'install.socket_confirm.cancelled')
                    exit 0
                }
            }
        }
    }

    if ($script:AGENTTEAMS_USE_EMBEDDED -ne "1") {
        # ============================================================
        # Legacy architecture: all-in-one manager container
        # (only entered when AGENTTEAMS_FORCE_LEGACY=1 — broken with the slim manager
        #  image shipped since PR #616; kept solely for AGENTTEAMS_VERSION <= v1.0.9)
        # ============================================================

        $dockerArgs = @(
            "run", "-d",
            "--name", "$($script:MANAGER_CONTAINER)",
            "--env-file", $script:AGENTTEAMS_ENV_FILE,
            "-e", "HOME=/root/manager-workspace",
            "-w", "/root/manager-workspace",
            "-e", "HOST_ORIGINAL_HOME=$($config.HOST_SHARE_DIR)",
            "-e", "AGENTTEAMS_MANAGER_RUNTIME=$($config.MANAGER_RUNTIME)"
        )

        $dockerArgs += @("-e", "TZ=$($script:AGENTTEAMS_TIMEZONE)")

        if ($script:AGENTTEAMS_MOUNT_SOCKET -and (Test-DockerRunning)) {
            $dockerArgs += @("--network", "$($script:DOCKER_NETWORK)")
            $dockerArgs += @("--network-alias", "matrix-local.agentteams.io")
            $dockerArgs += @("--network-alias", "aigw-local.agentteams.io")
            $dockerArgs += @("--network-alias", "fs-local.agentteams.io")
            foreach ($domain in @($config.MATRIX_CLIENT_DOMAIN, $config.CONSOLE_DOMAIN)) {
                if ($domain -match '-local\.agentteams\.io$') {
                    $dockerArgs += @("--network-alias", $domain)
                }
            }

            if ($config.DOCKER_PROXY -eq "1") {
                $proxyImage = $script:CONTROLLER_IMAGE
                Write-Log "Starting Docker API proxy..."
                docker rm -f $($script:CONTROLLER_CONTAINER) *>$null
                docker run -d --name $($script:CONTROLLER_CONTAINER) `
                    --network $($script:DOCKER_NETWORK) `
                    -v "//var/run/docker.sock:/var/run/docker.sock" `
                    --security-opt label=disable `
                    -e "AGENTTEAMS_WORKER_IMAGE=$($script:WORKER_IMAGE)" `
                    -e "AGENTTEAMS_COPAW_WORKER_IMAGE=$($script:COPAW_WORKER_IMAGE)" `
                    -e "AGENTTEAMS_QWENPAW_WORKER_IMAGE=$($script:QWENPAW_WORKER_IMAGE)" `
                    -e "AGENTTEAMS_OPENHUMAN_WORKER_IMAGE=$($script:OPENHUMAN_WORKER_IMAGE)" `
                    -e "AGENTTEAMS_HERMES_WORKER_IMAGE=$($script:HERMES_WORKER_IMAGE)" `
                    -e "AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_IMAGE=$($script:DEEPSEEK_HARNESS_WORKER_IMAGE)" `
                    -e "AGENTTEAMS_CODEX_WORKER_IMAGE=$($script:CODEX_WORKER_IMAGE)" `
                    -e "AGENTTEAMS_DEFAULT_WORKER_RUNTIME=$($script:config.DEFAULT_WORKER_RUNTIME)" `
                    $(if ($config.PROXY_ALLOWED_REGISTRIES) { @("-e", "AGENTTEAMS_PROXY_ALLOWED_REGISTRIES=$($config.PROXY_ALLOWED_REGISTRIES)") }) `
                    --restart unless-stopped `
                    $proxyImage
                $dockerArgs += @("-e", "AGENTTEAMS_CONTROLLER_URL=http://$($script:CONTROLLER_CONTAINER):8090")
                $dockerArgs += @("-e", "AGENTTEAMS_CONTAINER_API=http://$($script:CONTROLLER_CONTAINER):8090")
                Write-Log (Get-Msg "docker_proxy.selected_enabled")
            } else {
                $dockerArgs += @("-v", "//var/run/docker.sock:/var/run/docker.sock")
                $dockerArgs += @("--security-opt", "label=disable")
                Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value (Get-Msg "install.socket_detected" -f "//var/run/docker.sock")
            }
        }

        $dockerArgs += @("-p", "${portPrefix}$($config.PORT_GATEWAY):8080")
        $dockerArgs += @("-p", "${portPrefix}$($config.PORT_CONSOLE):8001")
        $dockerArgs += @("-p", "${portPrefix}$($config.PORT_ELEMENT_WEB):8088")
        $dockerArgs += @("-p", "127.0.0.1:$($config.PORT_MANAGER_CONSOLE):18888")

        $dockerArgs += @("-v", "$($config.DATA_DIR):/data")

        $wsDockerPath = ConvertTo-DockerPath -Path $config.WORKSPACE_DIR
        $dockerArgs += @("-v", "${wsDockerPath}:/root/manager-workspace")

        $shareDockerPath = ConvertTo-DockerPath -Path $config.HOST_SHARE_DIR
        $dockerArgs += @("-v", "${shareDockerPath}:/host-share")
        Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value (Get-Msg "host_share.sharing" -f $config.HOST_SHARE_DIR)

        if ($env:AGENTTEAMS_YOLO -eq "1") {
            $dockerArgs += @("-e", "AGENTTEAMS_YOLO=1")
            Write-Log (Get-Msg "install.yolo")
        }

        if ($env:AGENTTEAMS_MATRIX_DEBUG -eq "1") {
            $dockerArgs += @("-e", "AGENTTEAMS_MATRIX_DEBUG=1")
        }

        $dockerArgs += @("--restart", "unless-stopped")
        $dockerArgs += $managerImage
    }

    # Pull images (skip if already exists locally for local build tags).
    $LocalImagePattern = "^agentteams/"
    function Test-LocalImage {
        param([string]$Image)
        $imgExists = docker image inspect $Image 2>$null
        return $LASTEXITCODE -eq 0
    }
    if ($script:AGENTTEAMS_USE_EMBEDDED -eq "1") {
        # Embedded image was already pulled by Resolve-EmbeddedImage unless overridden;
        # for an explicit override we still need to ensure it is present locally.
        if ($env:AGENTTEAMS_INSTALL_EMBEDDED_IMAGE) {
            if ($script:EMBEDDED_IMAGE -match $LocalImagePattern) {
                if (Test-LocalImage $script:EMBEDDED_IMAGE) {
                    Write-Log (Get-Msg "install.image.embedded_exists" -f $script:EMBEDDED_IMAGE)
                } else {
                    Write-Log (Get-Msg "install.image.pulling_embedded" -f $script:EMBEDDED_IMAGE)
                    Invoke-DockerLogged -DockerArgs @('pull', $script:EMBEDDED_IMAGE)
                    if ($LASTEXITCODE -ne 0) { Exit-Script 1 }
                }
            } else {
                Write-Log (Get-Msg "install.image.pulling_embedded" -f $script:EMBEDDED_IMAGE)
                Invoke-DockerLogged -DockerArgs @('pull', $script:EMBEDDED_IMAGE)
                if ($LASTEXITCODE -ne 0) { Exit-Script 1 }
            }
        }
        # Manager image — controller will spawn it inside; pull here so the spawn doesn't
        # have to wait on the network.
        if ($managerImage -match $LocalImagePattern) {
            if (Test-LocalImage $managerImage) {
                Write-Log (Get-Msg "install.image.exists" -f $managerImage)
            } else {
                Write-Log (Get-Msg "install.image.pulling_manager" -f $managerImage)
                Invoke-DockerLogged -DockerArgs @('pull', $managerImage)
                if ($LASTEXITCODE -ne 0) { Exit-Script 1 }
            }
        } else {
            Write-Log (Get-Msg "install.image.pulling_manager" -f $managerImage)
            Invoke-DockerLogged -DockerArgs @('pull', $managerImage)
            if ($LASTEXITCODE -ne 0) { Exit-Script 1 }
        }
    } else {
        if ($managerImage -match $LocalImagePattern) {
            if (Test-LocalImage $managerImage) {
                Write-Log (Get-Msg "install.image.exists" -f $managerImage)
            } else {
                Write-Log (Get-Msg "install.image.pulling_manager" -f $managerImage)
                Invoke-DockerLogged -DockerArgs @('pull', $managerImage)
                if ($LASTEXITCODE -ne 0) { Exit-Script 1 }
            }
        } else {
            Write-Log (Get-Msg "install.image.pulling_manager" -f $managerImage)
            Invoke-DockerLogged -DockerArgs @('pull', $managerImage)
            if ($LASTEXITCODE -ne 0) { Exit-Script 1 }
        }
    }

    # Prepare Dashboard before stopping any existing service.
    if ($config.DASHBOARD -ne '0') {
        $dashboardImage = if ($config.DASHBOARD_IMAGE) { $config.DASHBOARD_IMAGE } else { "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-dashboard:$($config.DASHBOARD_VERSION)" }
        docker image inspect $dashboardImage *> $null
        if ($LASTEXITCODE -ne 0) { Write-Log (Get-Msg 'install.image.pulling_dashboard'); Invoke-DockerLogged -DockerArgs @('pull', $dashboardImage); if ($LASTEXITCODE -ne 0) { Write-Error 'Could not pull Dashboard image; existing services have not been stopped.' } }
    }

    Assert-UnifiedEntryImages

    # Preserve the original configuration before writing upgrade settings.
    $backup = $null
    if ($script:AGENTTEAMS_UPGRADE -and (Test-Path $script:AGENTTEAMS_ENV_FILE)) {
        $backup = "$($script:AGENTTEAMS_ENV_FILE).before-upgrade-$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item -LiteralPath $script:AGENTTEAMS_ENV_FILE -Destination $backup -ErrorAction Stop
        Write-Log (Get-Msg "output.backup")
        Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value "Config backup: $backup"
    }
    # Write env file
    New-EnvFile -Config $config -Path $script:AGENTTEAMS_ENV_FILE
    # Keep saved settings outside the generated template (for example external storage).
    if ($script:AGENTTEAMS_UPGRADE) {
        $savedLines = if ($backup) { Get-Content -LiteralPath $backup } else { $script:RecoveredConfig }
        $generated = Get-Content -LiteralPath $script:AGENTTEAMS_ENV_FILE
        foreach ($line in $savedLines) {
            if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { continue }
            $key = $Matches[1]
            if ($key -notlike 'AGENTTEAMS_*' -and $key -notin @('JVM_ARGS', 'DASHBOARD_SESSION_SECRET')) { continue }
            if ($generated -match "^${key}=") { continue }
            $value = [Environment]::GetEnvironmentVariable($key, 'Process')
            Add-Content -LiteralPath $script:AGENTTEAMS_ENV_FILE -Value "${key}=$value" -Encoding UTF8 -ErrorAction Stop
        }
    }

    # Check if the Docker volume exists; create if not (reuse on reinstall) — both modes.
    $volumeExists = docker volume ls -q 2>$null | Select-String "^$($config.DATA_DIR)$"
    if (-not $volumeExists) {
        docker volume create $config.DATA_DIR | Out-Null
    }

    # The controller pulls a Worker image when you create that Worker.

    # --- Pre-upgrade: extract Matrix passwords from old containers (old-arch -> embedded) ---
    $credsTmp = $null
    if ($script:AGENTTEAMS_UPGRADE -and $script:AGENTTEAMS_USE_EMBEDDED -eq "1") {
        $controllerNameHit = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:CONTROLLER_CONTAINER)$"
        $isOldArch = $false
        if (-not $controllerNameHit) {
            $isOldArch = $true
        } elseif (-not (Test-ExistingEmbeddedController $script:CONTROLLER_CONTAINER)) {
            $isOldArch = $true
        }

        if ($isOldArch) {
            $credsTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("agentteams-upgrade-creds-" + [Guid]::NewGuid().ToString("n"))
            New-Item -ItemType Directory -Path $credsTmp -Force | Out-Null
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false

            $mgrCredsTempStart = $false
            $mgrExists = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
            $mgrRunning = docker ps --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
            if ($mgrExists -and -not $mgrRunning) {
                Write-Log "$($script:MANAGER_CONTAINER) is stopped; starting it temporarily to extract Matrix credentials for upgrade..."
                docker start $($script:MANAGER_CONTAINER) 2>$null | Out-Null
                Wait-MatrixReady -Container "$($script:MANAGER_CONTAINER)" | Out-Null
                $mgrCredsTempStart = $true
            }

            $inspectLines = docker inspect $($script:MANAGER_CONTAINER) --format "{{range .Config.Env}}{{println .}}{{end}}" 2>$null
            $mgrPw = ""
            if ($inspectLines) {
                $envLine = $inspectLines -split "`n" | Where-Object { $_ -match '^AGENTTEAMS_MANAGER_PASSWORD=' } | Select-Object -First 1
                if ($envLine) {
                    $mgrPw = ($envLine -replace '^AGENTTEAMS_MANAGER_PASSWORD=', "").Trim()
                }
            }
            $mgrRunningNow = docker ps --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
            if ([string]::IsNullOrEmpty($mgrPw) -and $mgrRunningNow) {
                $mgrPw = docker exec $($script:MANAGER_CONTAINER) bash -c 'source /data/agentteams-secrets.env 2>/dev/null && echo "${AGENTTEAMS_MANAGER_PASSWORD}"' 2>$null
                if ($mgrPw) { $mgrPw = $mgrPw.Trim() }
            }
            $dataVolPresent = docker volume ls -q 2>$null | Where-Object { $_ -eq $config.DATA_DIR }
            if ([string]::IsNullOrEmpty($mgrPw) -and $dataVolPresent) {
                $mgrPw = Read-AgentTeamsSecretFromDataVolume -VolumeName $config.DATA_DIR -Key "AGENTTEAMS_MANAGER_PASSWORD"
            }

            $envFilePath = $script:AGENTTEAMS_ENV_FILE
            $mgrRoom = ""
            if (-not [string]::IsNullOrEmpty($mgrPw)) {
                $adminPw = ""
                $adminUser = "admin"
                if (Test-Path $envFilePath) {
                    $adminLine = Get-Content $envFilePath | Where-Object { $_ -match '^AGENTTEAMS_ADMIN_PASSWORD=' } | Select-Object -First 1
                    if ($adminLine) { $adminPw = ($adminLine -replace '^AGENTTEAMS_ADMIN_PASSWORD=', "").Trim() }
                    $userLine = Get-Content $envFilePath | Where-Object { $_ -match '^AGENTTEAMS_ADMIN_USER=' } | Select-Object -First 1
                    if ($userLine) {
                        $adminUser = ($userLine -replace '^AGENTTEAMS_ADMIN_USER=', "").Trim()
                        if ([string]::IsNullOrEmpty($adminUser)) { $adminUser = "admin" }
                    }
                }

                if (-not [string]::IsNullOrEmpty($adminPw) -and $mgrRunningNow) {
                    $mgrRoom = Get-AgentTeamsAdminDmRoomViaMatrix -AdminUser $adminUser -AdminPassword $adminPw
                }
                if ([string]::IsNullOrEmpty($mgrRoom)) {
                    $mgrRoom = Read-AgentTeamsAdminDmRoomFromWorkspace -WorkspaceDir $config.WORKSPACE_DIR
                }

                $gwKeyLine = if (Test-Path $envFilePath) {
                    Get-Content $envFilePath | Where-Object { $_ -match '^AGENTTEAMS_MANAGER_GATEWAY_KEY=' } | Select-Object -First 1
                } else { $null }
                $gwKeyForDefault = if ($gwKeyLine) { ($gwKeyLine -replace '^AGENTTEAMS_MANAGER_GATEWAY_KEY=', "").Trim() } else { $config.MANAGER_GATEWAY_KEY }

                $defaultEnvPath = Join-Path $credsTmp "default.env"
                [System.IO.File]::WriteAllLines($defaultEnvPath, @(
                    "WORKER_PASSWORD=$mgrPw"
                    "WORKER_MINIO_PASSWORD=$(Get-AgentTeamsRandomHex 24)"
                    "WORKER_GATEWAY_KEY=$gwKeyForDefault"
                    "WORKER_ROOM_ID=$mgrRoom"
                ), $utf8NoBom)
                if ($mgrRoom) {
                    Write-Log "Extracted Manager Matrix password and room ID"
                } else {
                    Write-Log "Extracted Manager Matrix password"
                }
            }

            if ($mgrCredsTempStart) {
                Write-Log "Stopping $($script:MANAGER_CONTAINER) after credential extraction (upgrade will recreate containers)..."
                docker stop $($script:MANAGER_CONTAINER) 2>$null | Out-Null
            }
        }
    }

    # Stop and remove existing containers (deferred until after all
    # configuration is collected and images are pulled successfully)
    $existingProxy = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:CONTROLLER_CONTAINER)$"
    if ($existingProxy) {
        docker stop $($script:CONTROLLER_CONTAINER) *>$null
        docker rm $($script:CONTROLLER_CONTAINER) *>$null
    }
    $existingContainer = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
    if ($existingContainer) {
        Write-Log (Get-Msg "install.removing_existing")
        docker stop $($script:MANAGER_CONTAINER) *>$null
        docker rm $($script:MANAGER_CONTAINER) *>$null
    }

    # Only legacy architecture migration needs Worker containers to be recreated.
    if ($isOldArch -and $script:UPGRADE_EXISTING_WORKERS) {
        Write-Log (Get-Msg "install.existing.stopping_workers")
        $script:UPGRADE_EXISTING_WORKERS | ForEach-Object {
            docker stop $_ *>$null
            docker rm $_ *>$null
            Write-Log (Get-Msg "install.existing.removed" -f $_)
        }
    }

    # --- Upgrade: inject extracted credentials into data volume (old-arch -> embedded) ---
    if ($credsTmp -and (Test-Path $credsTmp)) {
        $credsFiles = Get-ChildItem -Path $credsTmp -Filter "*.env" -ErrorAction SilentlyContinue
        if ($credsFiles -and $credsFiles.Count -gt 0) {
            $cleanupCtr = "$($script:AGENTTEAMS_RESOURCE_PREFIX)upgrade-cleanup"
            docker rm -f $cleanupCtr 2>$null | Out-Null
            $credsDockerPath = ConvertTo-DockerPath -Path $credsTmp
            $injectShell = "mkdir -p /data/worker-creds && cp /creds/*.env /data/worker-creds/ 2>/dev/null || true && chmod 600 /data/worker-creds/*.env 2>/dev/null || true"
            docker run --rm --name $cleanupCtr --entrypoint sh `
                -v "$($config.DATA_DIR):/data" `
                -v "${credsDockerPath}:/creds:ro" `
                $script:EMBEDDED_IMAGE `
                -c $injectShell 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Log "Injected credentials for upgrade"
            } else {
                Write-Log "Warning: credential injection failed, continuing"
            }
        }
        Remove-Item -Path $credsTmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($script:AGENTTEAMS_USE_EMBEDDED -eq "1") {
        # ============================================================
        # New architecture: embedded controller + auto-created manager
        # (controller container hosts Higress / Tuwunel / MinIO / Element Web /
        #  controller binary, then spawns the lightweight manager container)
        # ============================================================

        # Internal port: 8080 (Higress gateway inside the controller container).
        $internalGwPort = 8080

        $matrixDomain = if ($config.MATRIX_DOMAIN) {
            $config.MATRIX_DOMAIN
        } else {
            "matrix-local.agentteams.io:$($config.PORT_GATEWAY)"
        }
        $aigwDomain = if ($config.AI_GATEWAY_DOMAIN) { $config.AI_GATEWAY_DOMAIN } else { "aigw-local.agentteams.io" }
        if ($aigwDomain -notmatch ":") { $aigwDomain = "${aigwDomain}:${internalGwPort}" }
        $fsDomain = if ($config.FS_DOMAIN) { $config.FS_DOMAIN } else { "fs-local.agentteams.io" }
        if ($fsDomain -notmatch ":") { $fsDomain = "${fsDomain}:${internalGwPort}" }

        $ctrlArgs = @(
            "run", "-d",
            "--name", "$($script:CONTROLLER_CONTAINER)",
            "--network", "$($script:DOCKER_NETWORK)",
            "--network-alias", "matrix-local.agentteams.io",
            "--network-alias", "aigw-local.agentteams.io",
            "--network-alias", "fs-local.agentteams.io",
            "-e", "AGENTTEAMS_ADMIN_USER=$($config.ADMIN_USER)",
            "-e", "AGENTTEAMS_ADMIN_PASSWORD=$($config.ADMIN_PASSWORD)",
            "-e", "AGENTTEAMS_MANAGER_PASSWORD=$($config.MANAGER_PASSWORD)",
            "-e", "AGENTTEAMS_REGISTRATION_TOKEN=$($config.REGISTRATION_TOKEN)",
            "-e", "AGENTTEAMS_MINIO_USER=$($config.MINIO_USER)",
            "-e", "AGENTTEAMS_MINIO_PASSWORD=$($config.MINIO_PASSWORD)",
            "-e", "AGENTTEAMS_LLM_PROVIDER=$($config.LLM_PROVIDER)",
            "-e", "AGENTTEAMS_LLM_API_KEY=$($config.LLM_API_KEY)",
            "-e", "AGENTTEAMS_DEFAULT_MODEL=$($config.DEFAULT_MODEL)",
            "-e", "AGENTTEAMS_MANAGER_GATEWAY_KEY=$($config.MANAGER_GATEWAY_KEY)",
            "-e", "AGENTTEAMS_MANAGER_RUNTIME=$($config.MANAGER_RUNTIME)",
            "-e", "AGENTTEAMS_MANAGER_IMAGE=$managerImage",
            "-e", "AGENTTEAMS_DEFAULT_WORKER_RUNTIME=$($config.DEFAULT_WORKER_RUNTIME)",
            "-e", "AGENTTEAMS_WORKER_IMAGE=$($script:WORKER_IMAGE)",
            "-e", "AGENTTEAMS_COPAW_WORKER_IMAGE=$($script:COPAW_WORKER_IMAGE)",
            "-e", "AGENTTEAMS_QWENPAW_WORKER_IMAGE=$($script:QWENPAW_WORKER_IMAGE)",
            "-e", "AGENTTEAMS_OPENHUMAN_WORKER_IMAGE=$($script:OPENHUMAN_WORKER_IMAGE)",
            "-e", "AGENTTEAMS_HERMES_WORKER_IMAGE=$($script:HERMES_WORKER_IMAGE)",
            "-e", "AGENTTEAMS_DEEPSEEK_HARNESS_WORKER_IMAGE=$($script:DEEPSEEK_HARNESS_WORKER_IMAGE)",
            "-e", "AGENTTEAMS_CODEX_WORKER_IMAGE=$($script:CODEX_WORKER_IMAGE)",
            "-e", "AGENTTEAMS_MATRIX_DOMAIN=$matrixDomain",
            "-e", "AGENTTEAMS_ELEMENT_HOMESERVER_URL=http://127.0.0.1:$($config.PORT_GATEWAY)",
            "-e", "AGENTTEAMS_MATRIX_URL=http://127.0.0.1:6167",
            "-e", "AGENTTEAMS_MATRIX_E2EE=$($config.MATRIX_E2EE)",
            "-e", "AGENTTEAMS_MATRIX_APPSERVICE_ENABLED=$($config.MATRIX_APPSERVICE_ENABLED)",
            "-e", "AGENTTEAMS_MATRIX_APPSERVICE_AS_TOKEN=$($config.MATRIX_APPSERVICE_AS_TOKEN)",
            "-e", "AGENTTEAMS_MATRIX_APPSERVICE_HS_TOKEN=$($config.MATRIX_APPSERVICE_HS_TOKEN)",
            "-e", "AGENTTEAMS_MINIO_ENDPOINT=http://127.0.0.1:9000",
            "-e", "HIGRESS_ADMIN_WASM_PLUGIN_IMAGE_REGISTRY=$($config.HIGRESS_WASM_PLUGIN_REGISTRY)",
            "-e", "AGENTTEAMS_MINIO_BUCKET=agentteams-storage",
            "-e", "AGENTTEAMS_STORAGE_PREFIX=agentteams/agentteams-storage",
            "-e", "AGENTTEAMS_FS_ENDPOINT=http://127.0.0.1:9000",
            "-e", "AGENTTEAMS_AI_GATEWAY_URL=http://$aigwDomain",
            "-e", "AGENTTEAMS_CONTROLLER_URL=http://$($script:CONTROLLER_CONTAINER):8090",
            "-e", "AGENTTEAMS_DOCKER_NETWORK=$($script:DOCKER_NETWORK)",
            "-e", "AGENTTEAMS_RESOURCE_PREFIX=$($script:AGENTTEAMS_RESOURCE_PREFIX)",
            "-e", "AGENTTEAMS_WORKSPACE_DIR=$($config.WORKSPACE_DIR)",
            "-e", "AGENTTEAMS_HOST_SHARE_DIR=$($config.HOST_SHARE_DIR)",
            "-e", "AGENTTEAMS_MANAGER_ENABLED=true",
            "-e", "AGENTTEAMS_PORT_MANAGER_CONSOLE=$($config.PORT_MANAGER_CONSOLE)"
        )

        # Presigned download origin (#1501): every URL handed to a client
        # carries this host, so it must be reachable from the CALLER's
        # browser. The embedded Controller publishes only 8080/8001/8088,
        # so the in-container 127.0.0.1:9000 is not a browser endpoint —
        # presign stays disabled (501) unless the operator supplies one.
        if ($env:AGENTTEAMS_FS_PUBLIC_ENDPOINT) {
            $ctrlArgs += @("-e", "AGENTTEAMS_FS_PUBLIC_ENDPOINT=$($env:AGENTTEAMS_FS_PUBLIC_ENDPOINT)")
        }

        if ($script:AGENTTEAMS_TIMEZONE) {
            $ctrlArgs += @("-e", "TZ=$($script:AGENTTEAMS_TIMEZONE)")
        }
        if ($env:AGENTTEAMS_YOLO -eq "1") {
            $ctrlArgs += @("-e", "AGENTTEAMS_YOLO=1")
        }
        if ($env:AGENTTEAMS_MATRIX_DEBUG -eq "1") {
            $ctrlArgs += @("-e", "AGENTTEAMS_MATRIX_DEBUG=1")
        }
        if ($config.GITHUB_TOKEN) {
            $ctrlArgs += @("-e", "AGENTTEAMS_GITHUB_TOKEN=$($config.GITHUB_TOKEN)")
        }
        if ($config.EMBEDDING_MODEL) {
            $ctrlArgs += @("-e", "AGENTTEAMS_EMBEDDING_MODEL=$($config.EMBEDDING_MODEL)")
        }

        # Optional: custom model capability overrides (context window, max
        # tokens, vision, reasoning). These are read by the Controller's
        # config.go LoadConfig to annotate custom models not in the built-in
        # presets table.
        if ($config.MODEL_CONTEXT_WINDOW) {
            $ctrlArgs += @("-e", "AGENTTEAMS_MODEL_CONTEXT_WINDOW=$($config.MODEL_CONTEXT_WINDOW)")
        }
        if ($config.MODEL_MAX_TOKENS) {
            $ctrlArgs += @("-e", "AGENTTEAMS_MODEL_MAX_TOKENS=$($config.MODEL_MAX_TOKENS)")
        }
        if ($config.MODEL_VISION) {
            $ctrlArgs += @("-e", "AGENTTEAMS_MODEL_VISION=$($config.MODEL_VISION)")
        }
        if ($config.MODEL_REASONING) {
            $ctrlArgs += @("-e", "AGENTTEAMS_MODEL_REASONING=$($config.MODEL_REASONING)")
        }

        if ($config.OPENAI_BASE_URL) {
            $ctrlArgs += @("-e", "AGENTTEAMS_OPENAI_BASE_URL=$($config.OPENAI_BASE_URL)")
        }
        if ($env:AGENTTEAMS_AI_STREAM_IDLE_TIMEOUT_SECONDS) {
            $ctrlArgs += @("-e", "AGENTTEAMS_AI_STREAM_IDLE_TIMEOUT_SECONDS=$($env:AGENTTEAMS_AI_STREAM_IDLE_TIMEOUT_SECONDS)")
        }
        if ($script:AGENTTEAMS_LANGUAGE) {
            $ctrlArgs += @("-e", "AGENTTEAMS_LANGUAGE=$($script:AGENTTEAMS_LANGUAGE)")
        }

        # Optional: CMS/ARMS observability. In embedded mode the controller
        # spawns the Manager and Workers, so it must receive these settings.
        $cmsTracesEnabled = if ($env:AGENTTEAMS_CMS_TRACES_ENABLED) { $env:AGENTTEAMS_CMS_TRACES_ENABLED } else { "false" }
        $cmsServiceName = if ($env:AGENTTEAMS_CMS_SERVICE_NAME) { $env:AGENTTEAMS_CMS_SERVICE_NAME } else { "$($script:MANAGER_CONTAINER)" }
        $cmsMetricsEnabled = if ($env:AGENTTEAMS_CMS_METRICS_ENABLED) { $env:AGENTTEAMS_CMS_METRICS_ENABLED } else { "false" }
        $ctrlArgs += @("-e", "AGENTTEAMS_CMS_TRACES_ENABLED=$cmsTracesEnabled")
        $ctrlArgs += @("-e", "AGENTTEAMS_CMS_SERVICE_NAME=$cmsServiceName")
        $ctrlArgs += @("-e", "AGENTTEAMS_CMS_METRICS_ENABLED=$cmsMetricsEnabled")
        if ($env:AGENTTEAMS_CMS_ENDPOINT) {
            $ctrlArgs += @("-e", "AGENTTEAMS_CMS_ENDPOINT=$($env:AGENTTEAMS_CMS_ENDPOINT)")
        }
        if ($env:AGENTTEAMS_CMS_LICENSE_KEY) {
            $ctrlArgs += @("-e", "AGENTTEAMS_CMS_LICENSE_KEY=$($env:AGENTTEAMS_CMS_LICENSE_KEY)")
        }
        if ($env:AGENTTEAMS_CMS_PROJECT) {
            $ctrlArgs += @("-e", "AGENTTEAMS_CMS_PROJECT=$($env:AGENTTEAMS_CMS_PROJECT)")
        }
        if ($env:AGENTTEAMS_CMS_WORKSPACE) {
            $ctrlArgs += @("-e", "AGENTTEAMS_CMS_WORKSPACE=$($env:AGENTTEAMS_CMS_WORKSPACE)")
        }

        # Mount the docker socket so the controller can spawn manager + workers.
        $ctrlArgs += @("-v", "//var/run/docker.sock:/var/run/docker.sock")
        $ctrlArgs += @("--security-opt", "label=disable")

        # Persistent data + workspace mounts (manager workspace is bind-mounted under
        # /root/agentteams-fs/agents/manager so the controller can hand it to the spawned
        # manager container).
        $ctrlArgs += @("-v", "$($config.DATA_DIR):/data")
        $wsDockerPath = ConvertTo-DockerPath -Path $config.WORKSPACE_DIR
        $ctrlArgs += @("-v", "${wsDockerPath}:/root/agentteams-fs/agents/manager")
        Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value (Get-Msg "host_share.sharing" -f $config.HOST_SHARE_DIR)

        if ($config.UNIFIED_ENTRY -eq '1') {
            $ctrlArgs += @('-e', 'AGENTTEAMS_UNIFIED_ENTRY_ENABLED=true',
                '-e', "AGENTTEAMS_ENTRY_INTERNAL_URL=http://127.0.0.1:$($config.PORT_GATEWAY)",
                '-e', "AGENTTEAMS_ENTRY_EXTERNAL_URL=$($config.ENTRY_EXTERNAL_URL)")
            if ($config.DASHBOARD -ne '0') { $ctrlArgs += @('-e', "AGENTTEAMS_DASHBOARD_URL=http://$($script:DASHBOARD_CONTAINER):3000") }
        }
        # Externally exposed ports — only the gateway / Higress console / Element Web,
        # since the manager console is now spawned inside its own container by the
        # controller (port mapping is handled there).
        $ctrlArgs += @("-p", "${portPrefix}$($config.PORT_GATEWAY):8080")
        if ($config.UNIFIED_ENTRY -ne '1') {
            $ctrlArgs += @("-p", "${portPrefix}$($config.PORT_CONSOLE):8001")
            $ctrlArgs += @("-p", "${portPrefix}$($config.PORT_ELEMENT_WEB):8088")
        }

        $ctrlArgs += @("--restart", "unless-stopped")
        $ctrlArgs += $script:EMBEDDED_IMAGE

        Write-Log (Get-Msg "output.start_core")
        Invoke-DockerLogged -DockerArgs $ctrlArgs
        Write-Log (Get-Msg "output.core_started")

        # Wait for infra inside the controller container.
        function Wait-EmbeddedUrl {
            param([string]$Url, [string]$Container, [int]$MaxWait, [string]$Description)
            $elapsed = 0
            Write-Log (Get-Msg "output.wait_service" -f $Description)
            while ($elapsed -lt $MaxWait) {
                docker exec $Container curl -sf $Url *>$null
                if ($LASTEXITCODE -eq 0) {
                    Write-Log (Get-Msg "output.service_ready" -f $Description, $elapsed)
                    return $true
                }
                Start-Sleep -Seconds 2
                $elapsed += 2
            }
            Write-Host (Get-Msg "output.service_timeout" -f $Description, $MaxWait) -ForegroundColor Red
            return $false
        }

        if (-not (Wait-EmbeddedUrl "http://127.0.0.1:6167/_tuwunel/server_version" "$($script:CONTROLLER_CONTAINER)" 120 "Tuwunel (Matrix)")) { Exit-Script 1 }
        if (-not (Wait-EmbeddedUrl "http://127.0.0.1:9000/minio/health/live"        "$($script:CONTROLLER_CONTAINER)"  60 "MinIO"))             { Exit-Script 1 }
        if (-not (Wait-EmbeddedUrl "http://127.0.0.1:8080/status"                   "$($script:CONTROLLER_CONTAINER)" 120 "Higress Gateway"))   { Exit-Script 1 }

        if ($script:AGENTTEAMS_UPGRADE) {
            Update-InstalledManagerImage -Image $managerImage
        }

        # Wait for the controller to spawn the Manager Agent container.
        Write-Log (Get-Msg "output.wait_manager")
        $mgrWait = 0
        $mgrMax = 300
        while ($mgrWait -lt $mgrMax) {
            $found = docker ps --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
            $runningImage = docker inspect --format '{{.Config.Image}}' $script:MANAGER_CONTAINER 2>$null
            if ($found -and $runningImage -eq $managerImage) {
                Write-Log (Get-Msg "output.manager_detected" -f $mgrWait)
                break
            }
            Start-Sleep -Seconds 3
            $mgrWait += 3
        }
        if ($mgrWait -ge $mgrMax) {
            Write-Host (Get-Msg "output.manager_timeout" -f $mgrMax) -ForegroundColor Red
            Write-Log (Get-Msg "output.log_file" -f $script:AGENTTEAMS_LOG_FILE)
            docker exec $($script:CONTROLLER_CONTAINER) tail -30 /var/log/agentteams/agentteams-controller-error.log 2>$null
            Exit-Script 1
        }

        if ($env:AGENTTEAMS_YOLO -eq "1") {
            docker exec $($script:MANAGER_CONTAINER) touch /root/manager-workspace/yolo-mode 2>$null
        }

        # Wait for the Manager Agent's runtime + Matrix to be reachable. In embedded
        # mode Tuwunel lives in `agentteams-controller`, so the Matrix probe must target
        # the controller (the manager only exposes the agent runtime).
        Wait-ManagerReady -Container "$($script:MANAGER_CONTAINER)" | Out-Null
        Wait-MatrixReady -Container "$($script:CONTROLLER_CONTAINER)" | Out-Null

        Add-Content -LiteralPath $script:AGENTTEAMS_LOG_FILE -Value (Get-Msg "install.welcome_msg.background")
    } else {
        # Run container (legacy path)
        Write-Log (Get-Msg "install.starting_manager")
        Invoke-DockerLogged -DockerArgs $dockerArgs

        Wait-ManagerReady -Container "$($script:MANAGER_CONTAINER)" | Out-Null
        Wait-MatrixReady -Container "$($script:MANAGER_CONTAINER)" | Out-Null
    }

    # Embedded deployments let the Controller own provider configuration.
    if ($script:AGENTTEAMS_USE_EMBEDDED -ne "1" -and $config.LLM_PROVIDER -eq "openai-compat") {
        New-OpenAICompatProvider -BaseUrl $config.OPENAI_BASE_URL -ApiKey $config.LLM_API_KEY -ConsolePort ([int]$config.PORT_CONSOLE) | Out-Null
    }

    Start-AgentTeamsDashboard
    Wait-UnifiedEntry
    Show-InstallSummary
}

# ============================================================
# Worker Installation
# ============================================================

function Install-Worker {
    param(
        [string]$Name,
        [string]$Fs,
        [string]$FsKey,
        [string]$FsSecret,
        [switch]$Reset,
        [switch]$FindSkills,
        [string]$SkillsApiUrl
    )

    # Validate required parameters
    if (-not $Name) {
        Write-Error (Get-Msg "error.name_required")
    }
    if (-not $Fs) {
        Write-Error (Get-Msg "error.fs_required")
    }
    if (-not $FsKey) {
        Write-Error (Get-Msg "error.fs_key_required")
    }
    if (-not $FsSecret) {
        Write-Error (Get-Msg "error.fs_secret_required")
    }

    $containerName = "$($script:WORKER_CONTAINER_PREFIX)$Name"

    # Handle reset
    if ($Reset) {
        Write-Log (Get-Msg "worker.resetting" -f $Name)
        docker stop $containerName *>$null
        docker rm $containerName *>$null
    }

    # Check for existing container
    $existing = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$containerName$"
    if ($existing) {
        Write-Error (Get-Msg "worker.exists" -f $containerName)
    }

    # Detect timezone and registry
    $timezone = Get-AgentTeamsTimeZone
    $registry = Get-Registry -Timezone $timezone
    if (-not $env:AGENTTEAMS_INSTALL_WORKER_IMAGE) { throw "Standalone worker installation requires AGENTTEAMS_INSTALL_WORKER_IMAGE. Use agt create worker for managed Harness defaults." }
    $workerImage = if ($env:AGENTTEAMS_INSTALL_WORKER_IMAGE) {
        $env:AGENTTEAMS_INSTALL_WORKER_IMAGE
    } else {
        "$registry/agentteams/agentteams-harness-openclaw:${openclawVersion}"
    }
    $coreVersionMatch = [regex]::Match($script:AGENTTEAMS_VERSION, '^v?(\d+\.\d+\.\d+)')
    if (-not $env:AGENTTEAMS_INSTALL_WORKER_IMAGE -and $coreVersionMatch.Success -and [version]$coreVersionMatch.Groups[1].Value -lt [version]'1.2.7') {
        $workerImage = $workerImage.Replace('agentteams-harness-openclaw', 'agentteams-worker')
    }

    Write-Log (Get-Msg "worker.starting" -f $Name)

    $dockerArgs = @(
        "run", "-d",
        "--name", $containerName,
        "-e", "HOME=/root/agentteams-fs/agents/$Name",
        "-w", "/root/agentteams-fs/agents/$Name",
        "-e", "AGENTTEAMS_WORKER_NAME=$Name",
        "-e", "AGENTTEAMS_FS_ENDPOINT=$Fs",
        "-e", "AGENTTEAMS_FS_ACCESS_KEY=$FsKey",
        "-e", "AGENTTEAMS_FS_SECRET_KEY=$FsSecret"
    )

    if (-not $SkillsApiUrl) {
        if ($env:AGENTTEAMS_SKILLS_API_URL) {
            $SkillsApiUrl = $env:AGENTTEAMS_SKILLS_API_URL
        } else {
            $SkillsApiUrl = "nacos://market.agentteams.io:80/public"
        }
    }

    if ($FindSkills -and $SkillsApiUrl) {
        $dockerArgs += @("-e", "SKILLS_API_URL=$SkillsApiUrl")
        Write-Log (Get-Msg "worker.skills_url" -f $SkillsApiUrl)
    }
    if ($env:AGENTTEAMS_NACOS_USERNAME) {
        $dockerArgs += @("-e", "AGENTTEAMS_NACOS_USERNAME=$($env:AGENTTEAMS_NACOS_USERNAME)")
    }
    if ($env:AGENTTEAMS_NACOS_PASSWORD) {
        $dockerArgs += @("-e", "AGENTTEAMS_NACOS_PASSWORD=$($env:AGENTTEAMS_NACOS_PASSWORD)")
    }
    if ($env:AGENTTEAMS_NACOS_TOKEN) {
        $dockerArgs += @("-e", "AGENTTEAMS_NACOS_TOKEN=$($env:AGENTTEAMS_NACOS_TOKEN)")
    }

    $dockerArgs += @("--restart", "unless-stopped", $workerImage)

    Invoke-DockerLogged -DockerArgs $dockerArgs

    Write-Log ""
    Write-Log (Get-Msg "worker.started" -f $Name)
    Write-Log (Get-Msg "worker.container" -f $containerName)
    Write-Log (Get-Msg "worker.view_logs" -f $containerName)
}

# ============================================================
# Uninstall
# ============================================================

function Uninstall-AgentTeams {
    Write-Log (Get-Msg "uninstall.title")

    # Stop and remove manager
    $manager = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:MANAGER_CONTAINER)$"
    if ($manager) {
        Write-Log (Get-Msg "uninstall.stopping_manager")
        docker stop $($script:MANAGER_CONTAINER) *>$null
        docker rm $($script:MANAGER_CONTAINER) *>$null
    }

    # Stop and remove workers
    $workers = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:WORKER_CONTAINER_PREFIX)"
    if ($workers) {
        Write-Log (Get-Msg "uninstall.stopping_workers")
        $workers | ForEach-Object {
            docker stop $_ *>$null
            docker rm $_ *>$null
            Write-Log (Get-Msg "uninstall.removed" -f $_)
        }
    }

    # Stop and remove docker-proxy (legacy <= v1.0.x; current arch uses
    # agentteams-controller for the same role)
    $proxy = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:DOCKER_PROXY_CONTAINER)$"
    if ($proxy) {
        Write-Log (Get-Msg "uninstall.removing_proxy")
        docker stop $($script:DOCKER_PROXY_CONTAINER) *>$null
        docker rm $($script:DOCKER_PROXY_CONTAINER) *>$null
    }

    # Stop and remove the embedded controller container. MUST happen
    # before the `docker volume rm agentteams-data` step below -- in embedded
    # mode agentteams-controller mounts agentteams-data at /data (Tuwunel DB,
    # MinIO state, Higress state, all the room messages), and `volume rm`
    # against an in-use volume fails silently. Skipping this used to
    # leave room/message history behind across "uninstall + reinstall"
    # cycles. See PR #692.
    $controller = docker ps -a --format "{{.Names}}" 2>$null | Select-String "^$($script:CONTROLLER_CONTAINER)$"
    if ($controller) {
        Write-Log (Get-Msg "uninstall.stopping_controller")
        docker stop $($script:CONTROLLER_CONTAINER) *>$null
        docker rm $($script:CONTROLLER_CONTAINER) *>$null
    }

    # Remove Docker volume (read custom name from env file if available)
    $dataVolume = "$($script:DEFAULT_DATA_VOLUME)"
    if (Test-Path $script:AGENTTEAMS_ENV_FILE) {
        $envContent = Get-Content $script:AGENTTEAMS_ENV_FILE -ErrorAction SilentlyContinue
        $dataLine = $envContent | Select-String "^AGENTTEAMS_DATA_DIR="
        if ($dataLine) {
            $parsed = ($dataLine -split "=", 2)[1]
            if ($parsed) { $dataVolume = $parsed }
        }
    }
    $volume = docker volume ls -q 2>$null | Select-String "^${dataVolume}$"
    if ($volume) {
        Write-Log (Get-Msg "uninstall.removing_volume")
        docker volume rm $dataVolume *>$null
    }

    # Remove Docker network
    $network = docker network ls --format "{{.Name}}" 2>$null | Select-String "^$($script:DOCKER_NETWORK)$"
    if ($network) {
        Write-Log (Get-Msg "uninstall.removing_network")
        docker network rm $($script:DOCKER_NETWORK) *>$null
    }

    # Remove workspace directory
    $workspaceDir = "$env:USERPROFILE\$($script:MANAGER_CONTAINER)"
    if (Test-Path $script:AGENTTEAMS_ENV_FILE) {
        $envContent = Get-Content $script:AGENTTEAMS_ENV_FILE -ErrorAction SilentlyContinue
        $wsLine = $envContent | Select-String "^AGENTTEAMS_WORKSPACE_DIR="
        if ($wsLine) {
            $workspaceDir = ($wsLine -split "=", 2)[1]
        }
    }
    if ($workspaceDir -and (Test-Path $workspaceDir)) {
        Write-Log (Get-Msg "uninstall.removing_workspace" -f $workspaceDir)
        Remove-Item -Recurse -Force $workspaceDir -ErrorAction SilentlyContinue
    }

    # Remove env file
    if (Test-Path $script:AGENTTEAMS_ENV_FILE) {
        Write-Log (Get-Msg "uninstall.removing_env" -f $script:AGENTTEAMS_ENV_FILE)
        Remove-Item -Force $script:AGENTTEAMS_ENV_FILE
    }

    # Remove install log (stop transcript first to release the file)
    if (Test-Path $script:AGENTTEAMS_LOG_FILE) {
        Write-Log (Get-Msg "uninstall.removing_log" -f $script:AGENTTEAMS_LOG_FILE)
        try { Stop-Transcript *>$null } catch {}
        Remove-Item -Force $script:AGENTTEAMS_LOG_FILE -ErrorAction SilentlyContinue
    }

    Write-Log ""
    Write-Log (Get-Msg "uninstall.done")
}

# ============================================================
# Main Entry Point
# ============================================================

function Ensure-ContainerRuntime {
    if (Test-DockerRunning) { return }
    if (Get-Command podman -ErrorAction SilentlyContinue) {
        & podman info *> $null
        if ($LASTEXITCODE -eq 0) {
            Set-Alias -Name docker -Value podman -Scope Script
            return
        }
    }
    if ($script:AGENTTEAMS_NON_INTERACTIVE) { Write-Error (Get-Msg 'error.docker_not_running') }
    $dockerDesktop = @("$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe", "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($dockerDesktop) { Start-Process $dockerDesktop }
    elseif (Get-Command podman -ErrorAction SilentlyContinue) { Write-Log 'podman machine start' }
    else {
        $guide = 'https://docs.docker.com/desktop/setup/install/windows-install/'
        Write-Log "Docker Desktop: $guide"
        Start-Process $guide
    }
    if ($script:AGENTTEAMS_LANGUAGE -eq 'zh') { Write-Log '请安装并启动容器工具。此窗口会等待引擎就绪，然后自动继续（Ctrl+C 取消）。' }
    else { Write-Log 'Install and start your container tool. This window will continue when the engine is ready (Ctrl+C to cancel).' }
    Write-Log (Get-Msg 'output.runtime_missing')
    Write-Log (Get-Msg 'output.runtime_setup')
    Write-Log (Get-Msg 'output.runtime_wait')
    $started = Get-Date
    $nextStatus = $started
    $deadline = $started.AddMinutes(15)
    $env:PATH = "$env:PATH;$env:ProgramFiles\Docker\Docker\resources\bin;$env:LOCALAPPDATA\Programs\DockerDesktop\resources\bin"
    while ((Get-Date) -lt $deadline) {
        # Newly installed desktop tools may not be on this shell's original PATH.
        if (Test-DockerRunning) { return }
        if (Get-Command podman -ErrorAction SilentlyContinue) {
            & podman info *> $null
            if ($LASTEXITCODE -eq 0) { Set-Alias -Name docker -Value podman -Scope Script; return }
        }
        if ((Get-Date) -ge $nextStatus) {
            $elapsed = [int]((Get-Date) - $started).TotalSeconds
            Write-Log (Get-Msg 'output.runtime_progress' -f $elapsed)
            $nextStatus = (Get-Date).AddSeconds(30)
        }
        Start-Sleep -Seconds 3
    }
    Write-Error (Get-Msg 'error.docker_not_running')
}


function Initialize-UnifiedEntry {
    $version = if ($script:AGENTTEAMS_VERSION -eq 'latest') { $script:AGENTTEAMS_KNOWN_STABLE_VERSION } else { $script:AGENTTEAMS_VERSION }
    $match = [regex]::Match($version, '^v?(\d+\.\d+\.\d+)')
    $supported = $match.Success -and [version]$match.Groups[1].Value -ge [version]'1.2.8'
    $choice = $env:AGENTTEAMS_UNIFIED_ENTRY
    if (-not $choice) { $choice = $script:config.UNIFIED_ENTRY }
    if (-not $choice) { $choice = if ($supported -and -not $script:AGENTTEAMS_UPGRADE) { '1' } else { '0' } }
    if ($choice -eq '1' -and -not $supported) { throw 'Unified entry requires Core 1.2.8 or later; existing services have not been stopped.' }
    $script:config.UNIFIED_ENTRY = $choice
    if ($env:AGENTTEAMS_ENTRY_EXTERNAL_URL) { $script:config.ENTRY_EXTERNAL_URL = $env:AGENTTEAMS_ENTRY_EXTERNAL_URL }
    $rootImage = "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-dashboard:$($script:config.DASHBOARD_VERSION)"
    if (-not $script:config.DASHBOARD_IMAGE -or $script:config.DASHBOARD_IMAGE -in @($rootImage, "$rootImage-unified")) {
        $script:config.DASHBOARD_IMAGE = if ($choice -eq '1') { "$rootImage-unified" } else { $rootImage }
    }
}

function Get-UnifiedEntryUrl {
    if ($script:config.ENTRY_EXTERNAL_URL) { return $script:config.ENTRY_EXTERNAL_URL.TrimEnd('/') }
    $hostAddress = if ($script:config.LOCAL_ONLY -eq '0') { Get-LanIP } else { '127.0.0.1' }
    return "http://${hostAddress}:$($script:config.PORT_GATEWAY)"
}

function Get-DashboardBrowserUrl {
    if ($script:config.UNIFIED_ENTRY -eq '1') { return "$(Get-UnifiedEntryUrl)/dashboard/" }
    $port = if ($script:config.PORT_DASHBOARD) { $script:config.PORT_DASHBOARD } else { '13000' }
    return "http://127.0.0.1:${port}/"
}

function Assert-UnifiedEntryImages {
    if ($script:config.UNIFIED_ENTRY -ne '1') { return }
    if ($script:AGENTTEAMS_USE_EMBEDDED -ne '1') { throw 'Unified entry requires the embedded Controller.' }
    $label = docker image inspect --format '{{index .Config.Labels "io.agentteams.unified-entry"}}' $script:EMBEDDED_IMAGE
    if ($LASTEXITCODE -ne 0 -or "$label".Trim() -ne '1') { throw 'Controller image does not support unified entry; existing services have not been stopped.' }
    if ($script:config.DASHBOARD -ne '0') {
        $label = docker image inspect --format '{{index .Config.Labels "io.agentteams.dashboard-base-path"}}' $script:config.DASHBOARD_IMAGE
        if ($LASTEXITCODE -ne 0 -or "$label".Trim() -ne '/dashboard') { throw 'Dashboard image must support /dashboard; existing services have not been stopped.' }
    }
}

function Wait-UnifiedEntry {
    if ($script:config.UNIFIED_ENTRY -ne '1') { return }
    $entry = Get-UnifiedEntryUrl
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $token = (docker exec $script:CONTROLLER_CONTAINER cat /var/run/agentteams/cli-token 2>$null | Out-String).Trim()
            if (-not $token) { throw 'Controller credentials are not ready.' }
            $api = Invoke-RestMethod -Uri "$entry/api/v1/version" -Headers @{Authorization="Bearer $token"} -TimeoutSec 5 -ErrorAction Stop
            if (-not $api.controller) { throw 'Controller API is not ready.' }
            if ($script:config.DASHBOARD -ne '0') {
                $html = Invoke-WebRequest -UseBasicParsing -Uri "$entry/dashboard/" -TimeoutSec 5 -ErrorAction Stop
                $asset = [regex]::Match($html.Content, '/dashboard/_next/static/[^"<> ]+\.js')
                if (-not $asset.Success) { throw 'Dashboard assets are not ready.' }
                $null = Invoke-WebRequest -UseBasicParsing -Uri "$entry$($asset.Value)" -TimeoutSec 5 -ErrorAction Stop
                $null = Invoke-WebRequest -UseBasicParsing -Uri "$entry/dashboard/api/agentteams/healthz/" -TimeoutSec 5 -ErrorAction Stop
            }
            return
        } catch { Start-Sleep -Seconds 2 }
    }
    throw "Unified entry did not pass verification at $entry. Check Controller, Higress and Dashboard logs."
}

function Start-AgentTeamsDashboard {
    $script:AGENTTEAMS_DASHBOARD_READY = $false
    if ($script:config.DASHBOARD -eq '0' -or $script:AGENTTEAMS_USE_EMBEDDED -ne '1') { return }
    $version = if ($script:config.DASHBOARD_VERSION) { $script:config.DASHBOARD_VERSION } else { 'v1.4.3' }
    $image = if ($script:config.DASHBOARD_IMAGE) { $script:config.DASHBOARD_IMAGE } else { "$($script:AGENTTEAMS_REGISTRY)/agentteams/agentteams-dashboard:$version" }
    $port = if ($script:config.PORT_DASHBOARD) { $script:config.PORT_DASHBOARD } else { '13000' }
    $bindAddress = if ($script:config.LOCAL_ONLY -eq '0') { '0.0.0.0' } else { '127.0.0.1' }
    docker image inspect $image *> $null
    if ($LASTEXITCODE -ne 0) { Invoke-DockerLogged -DockerArgs @('pull', $image); if ($LASTEXITCODE -ne 0) { Write-Error 'Could not pull Dashboard image.' } }
    Write-Log (Get-Msg "output.start_dashboard")
    $token = $env:AGENTTEAMS_AUTH_TOKEN
    for ($attempt = 0; -not $token -and $attempt -lt 15; $attempt++) {
        $token = (docker exec $($script:CONTROLLER_CONTAINER) cat /var/run/agentteams/cli-token 2>$null | Out-String).Trim()
        if (-not $token) { Start-Sleep -Seconds 2 }
    }
    if (-not $token) { Write-Error 'Controller credentials are not ready for Dashboard.' }
    docker volume create $($script:DASHBOARD_VOLUME) *> $null
    docker run --rm --user 0 --entrypoint sh -v "$($script:DASHBOARD_VOLUME):/data/agentteams-dashboard" $image -c 'chown -R 1001:1001 /data/agentteams-dashboard' *> $null
    if ($LASTEXITCODE -ne 0) { Write-Error 'Could not prepare Dashboard storage.' }
    docker rm -f $($script:DASHBOARD_CONTAINER) *> $null
    $args = @('run', '-d', '--name', "$($script:DASHBOARD_CONTAINER)", '--restart', 'unless-stopped', '--network', "$($script:DOCKER_NETWORK)",
        '-v', "$($script:DASHBOARD_VOLUME):/data/agentteams-dashboard",
        '-e', 'AGENTTEAMS_DEPLOYMENT_MODE=embedded', '-e', "AGENTTEAMS_CONTROLLER_URL=http://$($script:CONTROLLER_CONTAINER):8090",
        '-e', "AGENTTEAMS_AUTH_TOKEN=$token", '-e', "AGENTTEAMS_MATRIX_URL=http://$($script:CONTROLLER_CONTAINER):6167",
        '-e', "MATRIX_HOMESERVER_ALLOWLIST=$($script:CONTROLLER_CONTAINER),matrix-local.agentteams.io",
        '-e', "AGENTTEAMS_AI_GATEWAY_URL=http://$($script:CONTROLLER_CONTAINER):8080",
        '-e', "AGENTTEAMS_AI_GATEWAY_ADMIN_URL=http://$($script:CONTROLLER_CONTAINER):8001",
        '-e', "AGENTTEAMS_AI_GATEWAY_ADMIN_ALLOWED_HOSTS=$($script:CONTROLLER_CONTAINER)",
        '-e', "AGENTTEAMS_FS_ENDPOINT=http://$($script:CONTROLLER_CONTAINER):9000",
        '-e', "AGENTTEAMS_FS_ACCESS_KEY=$($script:config.MINIO_USER)", '-e', "AGENTTEAMS_FS_SECRET_KEY=$($script:config.MINIO_PASSWORD)", $image)
    if ($script:config.UNIFIED_ENTRY -ne '1') { $args = $args[0..1] + @('-p', "${bindAddress}:${port}:3000") + $args[2..($args.Count-1)] }
    Invoke-DockerLogged -DockerArgs $args
    if ($LASTEXITCODE -ne 0) { Write-Error 'Could not start Dashboard.' }
    Wait-UnifiedEntry
    $url = "$(Get-DashboardBrowserUrl)?username=$([uri]::EscapeDataString($script:config.ADMIN_USER))"
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try {
            $null = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2 -ErrorAction Stop
            Write-Log (Get-Msg "output.dashboard_ready")
            $script:AGENTTEAMS_DASHBOARD_READY = $true
            if (-not $script:AGENTTEAMS_NON_INTERACTIVE) {
                try {
                    Set-Clipboard -Value $script:config.ADMIN_PASSWORD -ErrorAction Stop
                    if ($script:AGENTTEAMS_LANGUAGE -eq 'zh') { Write-Log '登录密码已复制，粘贴密码后点击登录即可。' }
                    else { Write-Log 'Login password copied. Paste it in Dashboard and sign in.' }
                } catch { Write-Log 'Copy the login password shown below.' }
                Start-Process $url
            }
            return
        } catch { Start-Sleep -Seconds 2 }
    }
    Write-Error "Dashboard did not become ready. Check: docker logs $($script:DASHBOARD_CONTAINER)"
}

try {
    switch ($Command) {
        { $_ -in @("manager", "reinstall") } {
            Install-Manager
        }
        "worker" {
            Install-Worker -Name $Name -Fs $Fs -FsKey $FsKey -FsSecret $FsSecret -Reset:$Reset -FindSkills:$FindSkills -SkillsApiUrl $SkillsApiUrl
        }
        "uninstall" {
            Uninstall-AgentTeams
        }
    }
} catch {
    Exit-Script 1
}

# Stop transcript logging
try {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
} catch {
    # Ignore errors when stopping transcript
}
