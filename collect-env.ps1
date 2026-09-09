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
# 후보 경로가 여러 개고 (흔한 세 위치 + App Paths 두 키) 보통 전부 같은 exe 를 가리킨다.
# 그대로 적으면 같은 줄이 세 번 찍혀 진단 파일만 지저분해지므로 이미 적은 경로는 건너뛴다.
# 서로 다른 경로가 나오는 경우가 진짜 정보다 (설치가 두 벌 있다는 뜻).
$seenChrome = New-Object System.Collections.Generic.List[string]

function Add-ChromePath {
    # 적었으면(또는 이미 적혀 있으면) $true. "찾았는가" 의 답이라 중복도 $true 다.
    param([string]$Label, [string]$Path)

    if (-not $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $key = $Path.ToLowerInvariant()
    if ($seenChrome.Contains($key)) { return $true }
    $seenChrome.Add($key)

    $ver = ''
    try { $ver = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo.ProductVersion } catch { }
    Add-Line $Label "$Path  (v$ver)"
    return $true
}

$chromeFound = $false
foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $root) { continue }
    if (Add-ChromePath 'Chrome' (Join-Path $root 'Google\Chrome\Application\chrome.exe')) {
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
        if (Add-ChromePath 'ChromeAppPath' $prop.'(default)') { $chromeFound = $true }
    }
    catch { }   # 레지스트리를 못 읽는 것 자체는 진단 실패가 아니다
}

if (-not $chromeFound) { Add-Line 'Chrome' '(찾지 못함)' }

$svc = Get-Service -Name 'GoogleChromeElevationService' -ErrorAction SilentlyContinue
if ($svc) { Add-Line 'ElevationService' "$($svc.Status) / $($svc.StartType)" }
else      { Add-Line 'ElevationService' '(없음)' }

# ── 첫 실행 차단 판별 ────────────────────────────────────────────────────────
# 인터넷에서 받은 파일에는 Zone.Identifier ADS 가 붙고, Windows 가 실행 전에 확인 창을
# 띄운다. 그 창은 PowerShell 보다 먼저 뜨므로 run-log.txt 에 남을 수 없다. 그래서 여기서
# 상태를 기록한다. 다음 수업에서 또 오류 창이 떴는데 이 줄이 '(없음)' 이면 MOTW 가 아니라
# 백신/정책이라는 뜻이다 - 그 판별이 이 줄의 목적이다.
$blocked = @(
    Get-ChildItem -LiteralPath $PSScriptRoot -File -ErrorAction SilentlyContinue |
        Where-Object { Get-Item -LiteralPath $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue } |
        ForEach-Object { $_.Name }
)
if ($blocked.Count -gt 0) { Add-Line 'BlockedFiles' (($blocked | Sort-Object) -join ', ') }
else                      { Add-Line 'BlockedFiles' '(없음)' }

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
