<#
    KServe 本地复现 · 版本一：直连复现
    ------------------------------------------------------------------
    全部走公网，不依赖任何本地中间产物：
      · KServe chart  : oci://ghcr.io/kserve/charts  （国内直连可达）
      · 容器镜像      : 经国内镜像源拉取后导入 kind 节点
      · 模型文件      : storage.googleapis.com 上的真实文件 URL

    用法（PowerShell，普通权限即可）：
      powershell -ExecutionPolicy Bypass -File .\PS-01-直连复现.ps1
      powershell -ExecutionPolicy Bypass -File .\PS-01-直连复现.ps1 -SkipCluster   # 复用已有集群
      powershell -ExecutionPolicy Bypass -File .\PS-01-直连复现.ps1 -FreshCluster  # 删掉集群重建

    依赖（本机已装好，脚本会自动定位）：
      C:\Users\<你>\.local\bin\  下的 kubectl.exe / kind.exe / helm.exe
#>
[CmdletBinding()]
param(
    [switch]$SkipCluster,     # 集群已存在则跳过创建
    [switch]$FreshCluster,    # 先删掉旧集群再重建
    [string]$ClusterName = 'kserve-demo',
    [string]$RegistryMirror = 'docker.m.daocloud.io',
    [string]$ModelUri = 'https://storage.googleapis.com/kfserving-examples/models/sklearn/1.0/model/model.joblib',
    [string]$WorkDir = "$env:TEMP\kserve-repro"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ─────────────────────────── 公共工具函数 ───────────────────────────

function Write-Step { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!]  $Msg" -ForegroundColor Yellow }

# 调用本地 exe；不因为 stderr 有输出就中断，只按退出码判断成败
function Invoke-Native {
    param([string]$Exe, [string[]]$ArgList, [string]$What = '命令')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @ArgList 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "$What 失败 (exit $code)`n$($out -join "`n")" }
    return $out
}

# 只取值不抛错，用于轮询
function Get-Native {
    param([string]$Exe, [string[]]$ArgList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @ArgList 2>&1 } finally { $ErrorActionPreference = $prev }
    return $out
}

function Write-Yaml {
    param([string]$Path, [string]$Content)
    # 用 UTF8 无 BOM 写文件，避免 PowerShell 5.1 的 Set-Content 写 BOM 干扰 YAML 解析
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Wait-Until {
    param([scriptblock]$Condition, [string]$What, [int]$TimeoutSec = 180)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        if (& $Condition) { return $true }
        Start-Sleep -Seconds 3
    }
    Write-Warn "$What 等待超时（${TimeoutSec}s）"
    return $false
}

# ─────────────────────────── 0. 环境准备 ───────────────────────────

Write-Step '0. 环境准备'

$bin = Join-Path $HOME '.local\bin'
foreach ($tool in 'kubectl', 'kind', 'helm') {
    $p = Join-Path $bin "$tool.exe"
    if (-not (Test-Path $p)) { throw "缺少 $tool.exe，期望路径：$p" }
}
$kubectl = Join-Path $bin 'kubectl.exe'
$kind    = Join-Path $bin 'kind.exe'
$helm    = Join-Path $bin 'helm.exe'
$env:PATH = "$bin;$env:PATH"
Write-Ok "kubectl / kind / helm 就位：$bin"

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

# 启动 Docker Desktop（per-user 安装）
$dockerExe = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'
if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $dockerExe)) { throw "找不到 Docker Desktop：$dockerExe" }
    Write-Host '  正在启动 Docker Desktop ...'
    Start-Process $dockerExe | Out-Null
}
$engineOk = Wait-Until -What 'Docker 引擎' -TimeoutSec 180 -Condition {
    (Get-Native 'docker' @('version','--format','{{.Server.Version}}')) -notmatch 'error|Error|无法|Cannot'
}
if (-not $engineOk) { throw 'Docker 引擎未能启动' }
Write-Ok "Docker 引擎就绪"

# ─────────────────────────── 1. kind 集群 ───────────────────────────

Write-Step '1. kind 集群'

$clusters = (Get-Native $kind @('get','clusters')) -join "`n"
if ($FreshCluster -and $clusters -match [regex]::Escape($ClusterName)) {
    Write-Host '  删除旧集群 ...'
    Invoke-Native $kind @('delete','cluster','--name',$ClusterName) '删除集群' | Out-Null
    $clusters = ''
}

if ($clusters -notmatch [regex]::Escape($ClusterName)) {
    if ($SkipCluster) { throw "指定了 -SkipCluster，但集群 $ClusterName 不存在" }

    # kind 配置里带上 containerd 镜像加速（国内拉镜像必需）
    $kindCfg = Join-Path $WorkDir 'kind-config.yaml'
    Write-Yaml $kindCfg @'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["https://docker.m.daocloud.io", "https://docker.1ms.run", "https://docker.1panel.live"]
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."quay.io"]
      endpoint = ["https://quay.m.daocloud.io", "https://quay.1ms.run"]
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
      - containerPort: 30081
        hostPort: 30081
'@
    Write-Host '  创建集群（已内置镜像加速）...'
    Invoke-Native $kind @('create','cluster','--name',$ClusterName,'--config',$kindCfg) '创建集群' | Out-Null
    Write-Ok "集群 $ClusterName 已创建"
} else {
    Write-Ok "复用已有集群 $ClusterName"
}

# 显式切到本脚本使用的集群（机器上若还有别的 kind 集群，kubectl 默认会打到那个去）
Invoke-Native $kubectl @('config','use-context',"kind-$ClusterName") '切换 kube context' | Out-Null

if (-not (Wait-Until -What 'K8s API' -TimeoutSec 180 -Condition {
    (Get-Native $kubectl @('get','nodes','--no-headers')) -match 'Ready'
})) { throw 'K8s API 未就绪' }
Write-Ok ((Get-Native $kubectl @('get','nodes','--no-headers')) -join "`n").Trim()

# ─────────────────────────── 2. cert-manager ───────────────────────────

Write-Step '2. cert-manager（KServe 前置依赖）'

# ⚠️ 不要从 GitHub releases 下载 cert-manager.yaml：
#    实测该 CDN 被限速到 ~1.6 KB/s，986 KB 要下 10 分钟且大概率超时。
#    改用 Helm 官方源 charts.jetstack.io（实测 2.5 s），镜像走 quay.io
#    （kind 节点已配 quay 镜像加速，见 containerdConfigPatches）。
$cmDep = (Get-Native $kubectl @('get','deployment','cert-manager','-n','cert-manager','--no-headers')) -join "`n"
if ($cmDep -match 'cert-manager') {
    Write-Ok 'cert-manager 已存在，跳过'
} else {
    Invoke-Native $helm @('repo','add','jetstack','https://charts.jetstack.io','--force-update') '添加 jetstack repo' | Out-Null
    Invoke-Native $helm @('repo','update','jetstack') '更新 repo' | Out-Null
    Invoke-Native $helm @('install','cert-manager','jetstack/cert-manager','--version','v1.16.1',
        '--namespace','cert-manager','--create-namespace','--set','installCRDs=true') '安装 cert-manager' | Out-Null
    Write-Ok 'cert-manager 安装完成'
}
Invoke-Native $kubectl @('wait','--for=condition=Available','--timeout=300s','deployment/cert-manager','-n','cert-manager') '等待 cert-manager' | Out-Null
Invoke-Native $kubectl @('wait','--for=condition=Available','--timeout=300s','deployment/cert-manager-webhook','-n','cert-manager') '等待 cert-manager-webhook' | Out-Null
Write-Ok 'cert-manager 就绪'

# ─────────────────────────── 3. KServe ───────────────────────────

Write-Step '3. 安装 KServe v0.17.0（OCI chart）'

$ver = 'v0.17.0'
if (-not (Get-Native $kubectl @('get','ns','kserve')) ) {
    Invoke-Native $kubectl @('create','ns','kserve') '创建 ns kserve' | Out-Null
}
$releases = (Get-Native $helm @('list','-n','kserve','--output','json')) -join "`n"
function Ensure-Chart {
    param([string]$Name, [string]$Chart, [string[]]$Extra = @())
    if ($releases -match "`"$Name`"") { Write-Ok "$Name 已安装，跳过"; return }
    Invoke-Native $helm (@('install',$Name,$Chart,'--version',$ver,'--namespace','kserve') + $Extra) "安装 $Name" | Out-Null
    Write-Ok "$Name 安装完成"
}
Ensure-Chart 'kserve-crd'           "oci://ghcr.io/kserve/charts/kserve-crd"
Ensure-Chart 'kserve-resources'     "oci://ghcr.io/kserve/charts/kserve-resources" @('--set','kserve.controller.deploymentMode=RawDeployment')
Ensure-Chart 'kserve-runtime-configs' "oci://ghcr.io/kserve/charts/kserve-runtime-configs"

# sklearn 运行时（v0.17 的 runtime-configs 不含 sklearn，需自行创建）
$rtFile = Join-Path $WorkDir 'sklearn-runtime.yaml'
Write-Yaml $rtFile @'
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterServingRuntime
metadata:
  name: kserve-sklearnserver
spec:
  containers:
    - name: kserve-container
      image: kserve/sklearnserver:v0.17.0
      args:
        - --model_name={{.Name}}
        - --model_dir=/mnt/models
        - --http_port=8080
      resources:
        limits:
          cpu: "1"
          memory: 1Gi
        requests:
          cpu: 100m
          memory: 256Mi
  supportedModelFormats:
    - name: sklearn
      version: "1"
      autoSelect: true
'@
Invoke-Native $kubectl @('apply','-f',$rtFile) '创建 sklearn ClusterRuntime' | Out-Null

if (-not (Wait-Until -What 'KServe controller' -TimeoutSec 240 -Condition {
    (Get-Native $kubectl @('get','pods','-n','kserve','--no-headers')) -match 'kserve-controller-manager.*1/1|kserve-controller-manager.*2/2'
})) { throw 'KServe controller 未就绪' }
Write-Ok 'KServe controller 就绪'

# ─────────────────────────── 4. 容器镜像（走国内镜像源） ───────────────────────────

Write-Step '4. 准备容器镜像（经镜像源）'

$image = 'kserve/sklearnserver:v0.17.0'
Write-Host "  经 $RegistryMirror 拉取 $image ..."
Invoke-Native 'docker' @('pull',"$RegistryMirror/$image") '拉取镜像' | Out-Null
Invoke-Native 'docker' @('tag',"$RegistryMirror/$image",$image) '打标签' | Out-Null
Write-Ok '镜像已拉取'

# 关键：不要用 `kind load docker-image`（内部带 --all-platforms，本地只有 amd64 会报
#       "content digest ... not found"）。改用 save → cp → 节点内 ctr import。
$tar = Join-Path $WorkDir 'sklearnserver.tar'
Write-Host '  docker save ...'
Invoke-Native 'docker' @('save','-o',$tar,$image) '导出镜像' | Out-Null

# 关键：kind 节点的 /tmp 是 tmpfs 挂载，docker cp 进去会「成功但文件不可见」。
#       必须拷到 /var/lib 这类真实目录。
Write-Host '  复制进 kind 节点 ...'
Invoke-Native 'docker' @('cp',$tar,"${ClusterName}-control-plane:/var/lib/sklearnserver.tar") '复制到节点' | Out-Null
Invoke-Native 'docker' @('exec','--privileged',"${ClusterName}-control-plane",
    'ctr','--namespace=k8s.io','images','import','--digests','--snapshotter=overlayfs','/var/lib/sklearnserver.tar') '导入节点镜像' | Out-Null
Invoke-Native 'docker' @('exec',"${ClusterName}-control-plane",'rm','-f','/var/lib/sklearnserver.tar') '清理' | Out-Null
Write-Ok '镜像已导入节点'

# ─────────────────────────── 5. 部署 InferenceService ───────────────────────────

Write-Step '5. 部署 InferenceService'

$isvcFile = Join-Path $WorkDir 'sklearn-isvc.yaml'
Write-Yaml $isvcFile @"
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris
  namespace: default
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      runtime: kserve-sklearnserver
      storageUri: "$ModelUri"
"@
# 注意 storageUri 必须指向【真实文件】。GCS 的「目录前缀」对 https 而言不是对象，
# initializer 对 http(s) 只做单文件 GET，指向目录必然 404。

Get-Native $kubectl @('delete','isvc','sklearn-iris','--ignore-not-found') | Out-Null
Invoke-Native $kubectl @('apply','-f',$isvcFile) '应用 ISvc' | Out-Null

# 重建 Pod，让 kubelet 用刚导入的本地镜像（imagePullPolicy 默认 IfNotPresent）
Get-Native $kubectl @('delete','pod','-l','serving.kserve.io/inferenceservice=sklearn-iris','--ignore-not-found') | Out-Null

$ready = Wait-Until -What 'ISvc Ready' -TimeoutSec 240 -Condition {
    (Get-Native $kubectl @('get','isvc','sklearn-iris','--no-headers')) -match '\sTrue\s'
}
if (-not $ready) {
    Write-Host (Get-Native $kubectl @('describe','isvc','sklearn-iris')) -join "`n"
    throw 'ISvc 未在超时内变为 READY=True'
}
Write-Ok 'ISvc READY=True'

# ─────────────────────────── 6. 推理验证 ───────────────────────────

Write-Step '6. 推理验证'

$pf = Start-Process -FilePath $kubectl -ArgumentList 'port-forward','svc/sklearn-iris-predictor','8080:80' -PassThru -NoNewWindow
try {
    Start-Sleep -Seconds 6
    $body = '{"instances": [[6.8,2.8,4.8,1.4],[5.1,3.5,1.4,0.2],[7.0,3.2,4.7,1.4]]}'
    $resp = Invoke-WebRequest -Uri 'http://localhost:8080/v1/models/sklearn-iris:predict' `
        -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 -UseBasicParsing
    Write-Ok "HTTP $($resp.StatusCode)  $($resp.Content)"
} finally {
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
}

Write-Step '完成'
Get-Native $kubectl @('get','isvc','sklearn-iris') | ForEach-Object { Write-Host $_ }
Get-Native $kubectl @('get','all','-l','serving.kserve.io/inferenceservice=sklearn-iris') | ForEach-Object { Write-Host $_ }
Write-Host "`n全流程跑通 ✅  可直接截图写简历。" -ForegroundColor Green
