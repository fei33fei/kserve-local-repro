<#
    KServe 本地复现 · 版本二：离线复现（用中间产物，不拉任何镜像）
    ------------------------------------------------------------------
    依赖的本地中间产物（脚本会自动定位，也可自行指定）：
      · 镜像归档  : sklearnserver.tar   (~183 MB, docker save 出来的)
      · 模型文件  : model-v2.joblib     (5408 bytes, 与在线版同源的新版 pickle)

    与版本一的区别：
      版本一  镜像走国内镜像源拉、模型走 Google 下载      → 需要外网
      版本二  镜像从本地 tar 导入、模型从本地文件挂载    → 不需要外网

    ⚠️ 前提：kind 集群 + KServe 已装好（版本一的前 3 步已完成）。
       集群本身无法离线创建，因为 Helm chart 来自 ghcr.io。
       集群不存在时本脚本会提示你先跑版本一。

    用法：
      powershell -ExecutionPolicy Bypass -File .\PS-02-离线复现.ps1
#>
[CmdletBinding()]
param(
    [string]$ClusterName = 'kserve-demo',
    [string]$AssetsDir  = '',
    [string]$ImageTar   = '',
    [string]$ModelFile  = '',
    [string]$RegistryMirror = 'docker.m.daocloud.io',
    [string]$WorkDir    = "$env:TEMP\kserve-offline"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step { param([string]$Msg) Write-Host "`n=== $Msg ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "  [!]  $Msg" -ForegroundColor Yellow }

function Invoke-Native {
    param([string]$Exe, [string[]]$ArgList, [string]$What = '命令')
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @ArgList 2>&1; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    if ($code -ne 0) { throw "$What 失败 (exit $code)`n$($out -join "`n")" }
    return $out
}
function Get-Native {
    param([string]$Exe, [string[]]$ArgList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Exe @ArgList 2>&1 } finally { $ErrorActionPreference = $prev }
    return $out
}
function Write-Yaml {
    param([string]$Path, [string]$Content)
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
$kubectl = Join-Path $bin 'kubectl.exe'
$kind    = Join-Path $bin 'kind.exe'
foreach ($p in @($kubectl, $kind)) { if (-not (Test-Path $p)) { throw "缺少 $p" } }
$env:PATH = "$bin;$env:PATH"
Write-Ok "kubectl / kind 就位"

# 中间产物默认取本包同级的中间产物\ 目录
if (-not $AssetsDir) { $AssetsDir = Join-Path $PSScriptRoot '中间产物' }

if (-not $ImageTar) { $ImageTar = Join-Path $AssetsDir 'sklearnserver.tar' }
if (-not $ModelFile) { $ModelFile = Join-Path $AssetsDir 'model-v2.joblib' }

if (-not (Test-Path $AssetsDir)) { throw "中间产物目录不存在：$AssetsDir" }
Write-Ok "中间产物目录：$AssetsDir"

$dockerExe = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'
if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $dockerExe)) { throw "找不到 Docker Desktop：$dockerExe" }
    Write-Host '  正在启动 Docker Desktop ...'
    Start-Process $dockerExe | Out-Null
}
if (-not (Wait-Until -What 'Docker 引擎' -TimeoutSec 180 -Condition {
    (Get-Native 'docker' @('version','--format','{{.Server.Version}}')) -notmatch 'error|Error|无法|Cannot'
})) { throw 'Docker 引擎未能启动' }
Write-Ok 'Docker 引擎就绪'

if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

# ─────────────────────────── 1. 前置检查 ───────────────────────────

Write-Step '1. 前置检查（集群 + KServe 必须已就绪）'

$clusters = (Get-Native $kind @('get','clusters')) -join "`n"
if ($clusters -notmatch [regex]::Escape($ClusterName)) {
    throw "集群 $ClusterName 不存在。离线复现无法凭空建集群（chart 在 ghcr.io），请先跑 PS-01-直连复现.ps1。"
}
Write-Ok "集群 $ClusterName 存在"

# 显式切到本脚本使用的集群（机器上若还有别的 kind 集群，kubectl 默认会打到那个去）
Invoke-Native $kubectl @('config','use-context',"kind-$ClusterName") '切换 kube context' | Out-Null

if (-not (Wait-Until -What 'K8s API' -TimeoutSec 180 -Condition {
    (Get-Native $kubectl @('get','nodes','--no-headers')) -match 'Ready'
})) { throw 'K8s API 未就绪' }

if (-not (Wait-Until -What 'KServe controller' -TimeoutSec 240 -Condition {
    (Get-Native $kubectl @('get','pods','-n','kserve','--no-headers')) -match 'kserve-controller-manager.*(1/1|2/2)'
})) { throw 'KServe controller 未就绪，请先跑 PS-01-直连复现.ps1' }
Write-Ok 'KServe controller 就绪'

$rt = (Get-Native $kubectl @('get','clusterservingruntime','kserve-sklearnserver','--no-headers')) -join "`n"
if ($rt -notmatch 'kserve-sklearnserver') {
    Write-Yaml (Join-Path $WorkDir 'sklearn-runtime.yaml') @'
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterServingRuntime
metadata:
  name: kserve-sklearnserver
spec:
  containers:
    - name: kserve-container
      image: kserve/sklearnserver:v0.17.0
      args: ["--model_name={{.Name}}", "--model_dir=/mnt/models", "--http_port=8080"]
      resources:
        limits: { cpu: "1", memory: 1Gi }
        requests: { cpu: 100m, memory: 256Mi }
  supportedModelFormats:
    - name: sklearn
      version: "1"
      autoSelect: true
'@
    Invoke-Native $kubectl @('apply','-f',(Join-Path $WorkDir 'sklearn-runtime.yaml')) '创建 ClusterRuntime' | Out-Null
    Write-Ok '已创建 sklearn ClusterRuntime'
} else {
    Write-Ok 'sklearn ClusterRuntime 已存在'
}

# ─────────────────────────── 2. 导入容器镜像（本地 tar，不联网） ───────────────────────────

Write-Step '2. 导入容器镜像'

$image = 'kserve/sklearnserver:v0.17.0'
if (Test-Path $ImageTar) {
    Write-Ok ("使用本地归档：{0}（{1} MB）" -f $ImageTar, [math]::Round((Get-Item $ImageTar).Length/1MB,1))
} else {
    Write-Warn "找不到本地归档 $ImageTar，退回镜像源拉取（此步骤需要外网）"
    Invoke-Native 'docker' @('pull',"$RegistryMirror/$image") '拉取镜像' | Out-Null
    Invoke-Native 'docker' @('tag',"$RegistryMirror/$image",$image) '打标签' | Out-Null
    $ImageTar = Join-Path $WorkDir 'sklearnserver.tar'
    Invoke-Native 'docker' @('save','-o',$ImageTar,$image) '导出镜像' | Out-Null
}

# ⚠️ 关键点 1：不要用 `kind load docker-image`
#    它内部用 ctr --all-platforms 导入，本地只有 amd64 会报
#    "content digest sha256:... not found"。
# ⚠️ 关键点 2：不要拷到节点的 /tmp
#    kind 节点的 /tmp 是 tmpfs 挂载，docker cp 会 exit 0 但文件在容器里【看不见】。
#    必须用 /var/lib 这类真实目录。
Write-Host '  复制进节点并导入 containerd ...'
Invoke-Native 'docker' @('cp',$ImageTar,"${ClusterName}-control-plane:/var/lib/sklearnserver.tar") '复制到节点' | Out-Null
Invoke-Native 'docker' @('exec','--privileged',"${ClusterName}-control-plane",
    'ctr','--namespace=k8s.io','images','import','--digests','--snapshotter=overlayfs','/var/lib/sklearnserver.tar') '导入节点镜像' | Out-Null
Invoke-Native 'docker' @('exec',"${ClusterName}-control-plane",'rm','-f','/var/lib/sklearnserver.tar') '清理' | Out-Null
Write-Ok '镜像已导入节点'

# ─────────────────────────── 3. 模型进节点 + PV/PVC ───────────────────────────

Write-Step '3. 模型进节点 + 建 PV/PVC'

if (-not (Test-Path $ModelFile)) { throw "找不到模型文件：$ModelFile" }
$modelSize = (Get-Item $ModelFile).Length
Write-Ok ("模型文件：{0}（{1} bytes）" -f $ModelFile, $modelSize)

if ($modelSize -lt 5000) {
    Write-Warn '模型文件偏小，常见于老版本 sklearn pickled 的文件（sklearn.svm.classes），'
    Write-Warn '新版 sklearn(1.x) 无法反序列化，会报 ModuleNotFoundError: sklearn.svm.classes。'
    Write-Warn '请换用 model-v2.joblib（5408 bytes）。'
}

Invoke-Native 'docker' @('exec',"${ClusterName}-control-plane",'mkdir','-p','/mnt/models') '节点建目录' | Out-Null
Invoke-Native 'docker' @('cp',$ModelFile,"${ClusterName}-control-plane:/var/lib/model.joblib") '复制模型' | Out-Null
Invoke-Native 'docker' @('exec',"${ClusterName}-control-plane",
    'sh','-c','rm -f /mnt/models/model.joblib && mv /var/lib/model.joblib /mnt/models/model.joblib && ls -lh /mnt/models/') '放入模型' | Out-Null
Write-Ok '模型已放到节点 /mnt/models/'

$pvFile = Join-Path $WorkDir 'model-pv-pvc.yaml'
Write-Yaml $pvFile @'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: model-pv
spec:
  capacity:
    storage: 100Mi
  accessModes: ["ReadOnlyMany"]
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /mnt/models
    type: Directory
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-pvc
  namespace: default
spec:
  accessModes: ["ReadOnlyMany"]
  resources:
    requests:
      storage: 100Mi
  storageClassName: ""
  volumeName: model-pv
'@
Invoke-Native $kubectl @('apply','-f',$pvFile) '创建 PV/PVC' | Out-Null
if (-not (Wait-Until -What 'PVC 绑定' -TimeoutSec 60 -Condition {
    (Get-Native $kubectl @('get','pvc','model-pvc','--no-headers')) -match '\sBound\s'
})) { throw 'PVC 未绑定，请检查 PV/PVC 描述' }
Write-Ok 'PVC model-pvc 已 Bound'

# ─────────────────────────── 4. 部署离线 InferenceService ───────────────────────────

Write-Step '4. 部署离线 InferenceService（pvc://）'

$isvcFile = Join-Path $WorkDir 'sklearn-isvc-offline.yaml'
Write-Yaml $isvcFile @'
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: sklearn-iris-offline
  namespace: default
spec:
  predictor:
    model:
      modelFormat:
        name: sklearn
      runtime: kserve-sklearnserver
      # ⚠️ 后面【不要】加 /model.joblib
      #    path 部分会被当成 SubPath，/mnt/models 会变成一个文件而不是目录，
      #    sklearnserver 会报 ModelMissingError。
      #    不带路径 = 整个 PVC 根目录挂到 /mnt/models，里面正好是 model.joblib。
      storageUri: "pvc://model-pvc"
'@
Get-Native $kubectl @('delete','isvc','sklearn-iris-offline','--ignore-not-found') | Out-Null
Invoke-Native $kubectl @('apply','-f',$isvcFile) '应用 ISvc' | Out-Null

# 用 pvc:// 时不会生成 storage-initializer 容器，模型直接挂载，不需要重建 Pod
$ready = Wait-Until -What '离线 ISvc Ready' -TimeoutSec 180 -Condition {
    (Get-Native $kubectl @('get','isvc','sklearn-iris-offline','--no-headers')) -match '\sTrue\s'
}
if (-not $ready) {
    Write-Host (Get-Native $kubectl @('describe','isvc','sklearn-iris-offline')) -join "`n"
    Write-Host (Get-Native $kubectl @('logs','-l','serving.kserve.io/inferenceservice=sklearn-iris-offline','-c','kserve-container','--tail=30')) -join "`n"
    throw '离线 ISvc 未在超时内变为 READY=True'
}
Write-Ok '离线 ISvc READY=True'

# ─────────────────────────── 5. 推理验证 ───────────────────────────

Write-Step '5. 推理验证'

$pf = Start-Process -FilePath $kubectl -ArgumentList 'port-forward','svc/sklearn-iris-offline-predictor','8080:80' -PassThru -NoNewWindow
try {
    Start-Sleep -Seconds 6
    $body = '{"instances": [[6.8,2.8,4.8,1.4],[5.1,3.5,1.4,0.2],[7.0,3.2,4.7,1.4]]}'
    $resp = Invoke-WebRequest -Uri 'http://localhost:8080/v1/models/sklearn-iris-offline:predict' `
        -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 -UseBasicParsing
    Write-Ok "HTTP $($resp.StatusCode)  $($resp.Content)"
} finally {
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
}

Write-Step '完成'
Get-Native $kubectl @('get','isvc','sklearn-iris-offline') | ForEach-Object { Write-Host $_ }
Get-Native $kubectl @('get','all','-l','serving.kserve.io/inferenceservice=sklearn-iris-offline') | ForEach-Object { Write-Host $_ }
Write-Host "`n离线复现跑通 ✅  全程未拉取任何容器镜像。" -ForegroundColor Green
