#!/usr/bin/env pwsh

<#
.SYNOPSIS
    啟動 AI 開發團隊 - 為每個角色打開獨立的 Claude Code 會話
.DESCRIPTION
    讀取 ~/.ai-team/projects.json 配置，為項目的每個角色啟動對應的 AI 模型。
    每個角色在獨立的 Windows Terminal 分頁中運行，使用指定的 Provider。
.PARAMETER Project
    項目名稱（對應 projects.json 中的 key）
.PARAMETER Role
    指定單個角色啟動（可選，默認啟動所有角色）
.PARAMETER List
    列出所有可用的項目和角色
.EXAMPLE
    .\start-ai-team.ps1 -Project tga-hr
    啟動 tga-hr 項目的所有角色
.EXAMPLE
    .\start-ai-team.ps1 -Project tga-hr -Role backend
    只啟動 tga-hr 項目的後端角色
.EXAMPLE
    .\start-ai-team.ps1 -List
    列出所有可用的項目和角色
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    $Project,

    [Parameter(Mandatory=$false)]
    $Role,

    [Parameter(Mandatory=$false)]
    [switch]$List
)

# 配置路徑
$ConfigPath = "$env:USERPROFILE\.ai-team\projects.json"

# 檢查配置文件是否存在
if (-not (Test-Path $ConfigPath)) {
    Write-Error "配置文件不存在: $ConfigPath"
    Write-Host "請先創建 ~/.ai-team/projects.json 配置文件" -ForegroundColor Yellow
    exit 1
}

# 讀取配置
try {
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
} catch {
    Write-Error "無法解析配置文件: $ConfigPath"
    Write-Error $_.Exception.Message
    exit 1
}

# 列出模式
if ($List) {
    Write-Host "📋 可用項目和角色" -ForegroundColor Cyan
    Write-Host ""
    foreach ($projName in $Config.projects.PSObject.Properties.Name) {
        $proj = $Config.projects.$projName
        Write-Host "  📁 $($proj.name) ($projName)" -ForegroundColor Green
        Write-Host "     描述: $($proj.description)" -ForegroundColor Gray
        foreach ($roleName in $proj.roles.PSObject.Properties.Name) {
            $r = $proj.roles.$roleName
            Write-Host "     👤 $($r.title) ($roleName) → $($r.provider)" -ForegroundColor White
        }
        Write-Host ""
    }
    exit 0
}

# 驗證項目參數
if (-not $Project) {
    Write-Error "請指定項目名稱，使用 -Project 參數"
    Write-Host "可用項目:" -ForegroundColor Yellow
    foreach ($projName in $Config.projects.PSObject.Properties.Name) {
        $proj = $Config.projects.$projName
        Write-Host "  - $projName ($($proj.name))" -ForegroundColor White
    }
    Write-Host ""
    Write-Host "使用 -List 查看詳細信息" -ForegroundColor Gray
    exit 1
}

# 查找項目
$SelectedProject = $Config.projects.$Project
if (-not $SelectedProject) {
    Write-Error "項目 '$Project' 不存在"
    Write-Host "可用項目:" -ForegroundColor Yellow
    foreach ($projName in $Config.projects.PSObject.Properties.Name) {
        Write-Host "  - $projName" -ForegroundColor White
    }
    exit 1
}

Write-Host "🚀 啟動項目: $($SelectedProject.name)" -ForegroundColor Cyan
Write-Host "   描述: $($SelectedProject.description)" -ForegroundColor Gray
Write-Host ""

# 收集角色列表 - 使用 $roleItem 避免覆蓋 $Role 參數
$RolesToStart = @()
foreach ($roleName in $SelectedProject.roles.PSObject.Properties.Name) {
    $roleItem = $SelectedProject.roles.$roleName
    $roleItem | Add-Member -NotePropertyName 'name' -NotePropertyValue $roleName -Force
    $RolesToStart += $roleItem
}

# 過濾角色 - 檢查 $Role 是否為空
$hasRoleFilter = $Role -and ($Role -ne '')
if ($hasRoleFilter) {
    $FilteredRoles = @()
    foreach ($r in $RolesToStart) {
        if ($r.name -eq $Role) {
            $FilteredRoles += $r
        }
    }
    $RolesToStart = $FilteredRoles
    if ($RolesToStart.Count -eq 0) {
        Write-Error "角色 '$Role' 不存在於項目 '$Project'"
        Write-Host "可用角色:" -ForegroundColor Yellow
        foreach ($r in $SelectedProject.roles.PSObject.Properties.Name) {
            $roleObj = $SelectedProject.roles.$r
            Write-Host "  - $r ($($roleObj.title))" -ForegroundColor White
        }
        exit 1
    }
}

# 檢查 ccsc 是否可用
$ccscCmd = Get-Command ccsc -ErrorAction SilentlyContinue
$ccscPath = $null
if ($ccscCmd) {
    $ccscPath = $ccscCmd.Source
}

if (-not $ccscPath) {
    # 嘗試全局安裝的 ccsc
    $ccscPath = "$env:APPDATA\npm\ccsc.cmd"
    if (-not (Test-Path $ccscPath)) {
        Write-Error "找不到 ccsc 命令，請先安裝: npm install -g @terranc/ccsc"
        exit 1
    }
}

Write-Host "✓ 使用 ccsc: $ccscPath" -ForegroundColor Green
Write-Host ""

# 啟動每個角色
foreach ($r in $RolesToStart) {
    $title = $r.title
    $provider = $r.provider
    $workDir = $r.workdir

    Write-Host "👤 啟動角色: $($r.title) ($($r.name))" -ForegroundColor Cyan
    Write-Host "   Provider: $provider" -ForegroundColor Gray
    Write-Host "   工作目錄: $workDir" -ForegroundColor Gray

    # 构建命令块（多行字符串，无需手动转义）
    $commandBlock = @"
Write-Host '🚀 啟動 Claude Code [$title]' -ForegroundColor Cyan
Write-Host '   Provider: $provider' -ForegroundColor Gray
Write-Host '   項目: $($SelectedProject.name)' -ForegroundColor Gray
Write-Host ''
ccsc --provider '$provider'
"@

    # 将命令块转为 Base64 编码（支持 Unicode）
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($commandBlock)
    $encodedCommand = [Convert]::ToBase64String($bytes)

    # 构造 Windows Terminal 参数
    $wtExe = 'C:\MyWork\terminal-1.24.10921.0\WindowsTerminal.exe'
    $wtArgs = "new-tab --title `"$title`" --startingDirectory `"$workDir`" powershell -NoExit -EncodedCommand $encodedCommand"

    try {
        $proc = Start-Process $wtExe -Verb runAs -ArgumentList $wtArgs -PassThru -ErrorAction Stop
        Write-Host "   ✓ 已啟動 (PID: $($proc.Id))" -ForegroundColor Green
    } catch {
        Write-Error "   ✗ 啟動失敗: $_"
        Write-Host "   嘗試直接啟動 ccsc..." -ForegroundColor Yellow
        Start-Process -FilePath $ccscPath -ArgumentList "--provider", $provider -WorkingDirectory $workDir
    }

    Start-Sleep -Milliseconds 1000
    Write-Host ""
}

Write-Host "✅ 所有角色已啟動完成!" -ForegroundColor Green
Write-Host "   項目: $($SelectedProject.name)" -ForegroundColor Gray
Write-Host "   角色數: $($RolesToStart.Count)" -ForegroundColor Gray
