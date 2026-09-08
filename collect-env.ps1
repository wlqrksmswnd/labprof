<#
  collect-env.ps1 - Step 0 진단

  왜 필요한가:
    Chrome 쿠키는 현재 Windows 사용자의 DPAPI 마스터 키로 묶여 있다.
    프로필 파일이 살아남아도 그 키가 같이 살아남지 않으면 Chrome은 조용히
    새 키를 만들고 기존 쿠키를 버린다 = 로그아웃. 그러면 이 도구 전체가 무의미해진다.

    실습실 초기화가
      - 스냅샷 복원형(복원솔루션/Deep Freeze류) -> SID/DPAPI 키가 매 부팅 동일 -> 성립
      - 프로필 재생성형                          -> 매 부팅 다름                -> 불성립
    인지를 추측하지 않고 실측한다.

  사용법:
    1) 실습실 PC 에서 실행
    2) 완전 종료 후 재부팅 (실제 초기화가 일어나야 한다)
    3) 다시 실행
    4) 옆에 생긴 env-log.txt 의 두 블록을 비교

  판정:
    SID 와 UserDpapiKeys 가 두 블록에서 같으면 -> lab-profile.ps1 로 진행
    하나라도 다르면                            -> 플랜 부록의 폴백(KeePassXC+TOTP / FIDO2)

  모든 조회는 실패해도 죽지 않고 빈 값으로 기록된다 (권한 부족이 흔하다).
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$LogPath = Join-Path $PSScriptRoot 'env-log.txt'


function Get-GuidNames {
    # 폴더 안의 GUID 형식 이름만. DPAPI 마스터 키 파일이 이 형식이다.
    param([string]$Path)

    if (-not $Path) { return '' }
    if (-not (Test-Path -LiteralPath $Path)) { return '(경로 없음)' }

    $names = @(
        Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$' } |
            ForEach-Object { $_.Name } |
            Sort-Object
    )

    if ($names.Count -eq 0) { return '(없음 - 권한 부족이거나 비어 있음)' }
    return ($names -join ', ')
}


$lines = New-Object System.Collections.Generic.List[string]

function Add-Line {
    param([string]$Label, $Value)
    if ($null -eq $Value -or "$Value" -eq '') { $Value = '(빈 값)' }
    $lines.Add(("  {0,-22}: {1}" -f $Label, $Value))
}

$lines.Add('')
$lines.Add(('=' * 78))
$lines.Add("실행 시각: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add(('=' * 78))

# ── 기본 ─────────────────────────────────────────────────────────────────────
Add-Line 'COMPUTERNAME' $env:COMPUTERNAME
Add-Line 'USERNAME'     $env:USERNAME
Add-Line 'USERPROFILE'  $env:USERPROFILE
Add-Line 'PSVersion'    $PSVersionTable.PSVersion.ToString()
Add-Line 'OS'           (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption

# ── 판정의 핵심 1: SID ───────────────────────────────────────────────────────
$sid = ''
try   { $sid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value }
catch { $sid = "(조회 실패: $($_.Exception.Message))" }
Add-Line 'SID' $sid

# ── 판정의 핵심 2: 사용자 DPAPI 마스터 키 ────────────────────────────────────
$userProtect = ''
if ($sid -and $sid -like 'S-1-*') {
    $userProtect = Join-Path $env:APPDATA "Microsoft\Protect\$sid"
}
Add-Line 'UserProtectPath' $userProtect
Add-Line 'UserDpapiKeys'   (Get-GuidNames $userProtect)

# ── 참고: SYSTEM DPAPI (App-Bound Encryption 용, 보통 권한 부족으로 빈다) ────
Add-Line 'SystemDpapiKeys' (Get-GuidNames 'C:\Windows\System32\Microsoft\Protect\S-1-5-18')

# ── Chrome ───────────────────────────────────────────────────────────────────
$chromeFound = $false
foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $root) { continue }
    $p = Join-Path $root 'Google\Chrome\Application\chrome.exe'
    if (Test-Path -LiteralPath $p) {
        $ver = ''
        try { $ver = (Get-Item -LiteralPath $p -ErrorAction Stop).VersionInfo.ProductVersion } catch { }
        Add-Line 'Chrome' "$p  (v$ver)"
        $chromeFound = $true
    }
}

# 흔한 세 위치에 없을 수도 있다. 레지스트리의 App Paths 도 본다.
# (Find-LPChrome 과 같은 조회지만 일부러 따로 둔다. 이 스크립트는 다른 파일이
#  깨져 있어도 혼자 돌아야 하고, 하는 일도 다르다 - 전부 나열 vs 첫 개.)
$appPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
)
foreach ($key in $appPaths) {
    try {
        $prop = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $prop) { continue }
        $p = $prop.'(default)'
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        $ver = ''
        try { $ver = (Get-Item -LiteralPath $p -ErrorAction Stop).VersionInfo.ProductVersion } catch { }
        Add-Line 'ChromeAppPath' "$p  (v$ver)"
        $chromeFound = $true
    }
    catch { }   # 레지스트리를 못 읽는 것 자체는 진단 실패가 아니다
}

if (-not $chromeFound) { Add-Line 'Chrome' '(찾지 못함)' }

$svc = Get-Service -Name 'GoogleChromeElevationService' -ErrorAction SilentlyContinue
if ($svc) { Add-Line 'ElevationService' "$($svc.Status) / $($svc.StartType)" }
else      { Add-Line 'ElevationService' '(없음)' }

# ── 실행 정책 (start.bat 이 Bypass 로 우회하지만 AppLocker 는 별개) ──────────
$policies = @(
    Get-ExecutionPolicy -List -ErrorAction SilentlyContinue |
        ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }
)
Add-Line 'ExecutionPolicy' ($policies -join ' ')

# ── D: 드라이브 ──────────────────────────────────────────────────────────────
$d = Get-PSDrive -Name 'D' -ErrorAction SilentlyContinue
if ($d) {
    $freeGb = if ($null -ne $d.Free) { [math]::Round($d.Free / 1GB, 1) } else { '?' }
    Add-Line 'D: 드라이브' "있음 (여유 ${freeGb}GB)"
}
else { Add-Line 'D: 드라이브' '(없음)' }


# ── 출력 + 기록 ──────────────────────────────────────────────────────────────
$text = $lines -join "`r`n"
Write-Host $text

# PS 5.1 의 Out-File -Encoding utf8 은 BOM 을 붙이지만 append 라도 매번 붙지는 않는다.
# 메모장에서 열어 볼 파일이므로 UTF-8 로 통일한다.
Add-Content -LiteralPath $LogPath -Value $text -Encoding UTF8

Write-Host ''
Write-Host "기록: $LogPath" -ForegroundColor Green
Write-Host ''
Write-Host '다음: 이 PC 를 완전히 종료했다가 다시 켠 뒤 이 스크립트를 한 번 더 실행하고,' -ForegroundColor Yellow
Write-Host '      env-log.txt 의 두 블록에서 SID 와 UserDpapiKeys 가 같은지 비교하세요.' -ForegroundColor Yellow
Write-Host '      같으면 진행 가능, 다르면 이 방식은 이 PC 에서 성립하지 않습니다.' -ForegroundColor Yellow
