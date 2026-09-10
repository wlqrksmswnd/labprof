<#
  change-password.ps1 - 컨테이너 비밀번호 교체

  Google 계정 비밀번호와는 아무 관계가 없다. 이건 컨테이너를 여는 열쇠만 바꾼다.
  (Google 비밀번호를 바꿨을 때는 이 스크립트를 쓸 필요가 없다. 그냥 start.bat 으로
   열어서 새 비밀번호로 한 번 로그인하면 종료할 때 자동으로 갱신된다.)

  압축을 풀지 않고 컨테이너 계층에서만 재암호화하므로 빠르다.
  비밀번호가 바뀌므로 salt 도 새로 만든다.

  실행은 change-password.bat 으로 한다.
  change-password.bat hong  처럼 슬롯 이름을 주면 선택 메뉴를 건너뛴다.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Slot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-LPBootError {
    <#
      Start-LPLog 보다 앞선 구간의 오류를 run-log.txt 에 직접 붙여 쓴다.
      lab-profile.ps1 에 같은 함수가 있다 - 왜 공용 파일로 못 빼는지는 그쪽 주석 참고.
      (요약: log.ps1 을 못 불러온 경우가 이 함수가 필요한 경우에 포함된다.)
    #>
    param([Parameter(Mandatory)][string]$Message)

    Write-Host ''
    Write-Host $Message -ForegroundColor Red
    Write-Host ''

    $logPath = Join-Path $PSScriptRoot 'run-log.txt'
    try {
        $text = "`r`n[boot-error] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n$Message`r`n"
        if (Test-Path -LiteralPath $logPath) {
            [System.IO.File]::AppendAllText($logPath, $text, (New-Object System.Text.UTF8Encoding($false)))
        }
        else {
            [System.IO.File]::WriteAllText($logPath, $text, (New-Object System.Text.UTF8Encoding($true)))
        }
        Write-Host "이 내용은 $logPath 에도 남았습니다." -ForegroundColor DarkGray
    }
    catch {
        Write-Host "(run-log.txt 에 남기지 못했습니다: $($_.Exception.Message))" -ForegroundColor DarkGray
        Write-Host '화면을 사진으로 남겨 두세요.' -ForegroundColor Yellow
    }

    Write-Host '창을 닫고 한 번 더 실행해 보세요. 그래도 같으면 위 내용을 가져와서 보여 주세요.' -ForegroundColor Yellow
}


# ── 라이브러리 로드 ──────────────────────────────────────────────────────────
# lab-profile.ps1 과 같은 가드다 (Start-LPLog 앞 구간을 D: 에 남긴다).
# profile-lib.ps1 은 일부러 넣지 않는다 - 비밀번호 교체에는 Chrome 코드가 필요 없다.
$LibFiles = @('crypto.ps1', 'slots.ps1', 'log.ps1')

$missingLibs = @(
    $LibFiles | Where-Object {
        $p = Join-Path $PSScriptRoot $_
        (-not (Test-Path -LiteralPath $p -PathType Leaf)) -or ((Get-Item -LiteralPath $p).Length -eq 0)
    }
)
if ($missingLibs.Count -gt 0) {
    Write-LPBootError ("필요한 파일이 없거나 비어 있습니다: $($missingLibs -join ', ')`r`n" +
                       '폴더 전체를 D: 로 다시 복사하세요.')
    exit 1
}

try {
    foreach ($lib in $LibFiles) { . (Join-Path $PSScriptRoot $lib) }
}
catch {
    Write-LPBootError ("스크립트를 불러오는 중 오류가 났습니다.`r`n" +
                       "$($_.Exception.Message)`r`n$($_.ScriptStackTrace)")
    exit 1
}

[void](Start-LPLog -Root $PSScriptRoot -Tag 'change-password')

try {
    Write-Host ''
    Write-Host '=== 컨테이너 비밀번호 변경 ===' -ForegroundColor Cyan

    # 재암호화도 %TEMP% 에 평문 zip 을 한 번 펼친다. 비정상 종료로 남은 것이 있으면
    # 먼저 치운다 (start.bat 과 같은 이유. 남는 것이 남의 로그인된 프로필이다).
    [void](Remove-LPStaleStaging)

    # 없는 슬롯의 비밀번호를 바꿀 일은 없으므로 -AllowNew 를 주지 않는다.
    if ($Slot) {
        if (-not (Test-LPSlotName $Slot)) {
            Write-Host "슬롯 이름으로 쓸 수 없습니다: '$Slot'" -ForegroundColor Red
            exit 1
        }
        $slotName      = $Slot
        $ContainerPath = Get-LPSlotPath -Root $PSScriptRoot -Name $Slot
    }
    else {
        $sel = Select-LPSlot -Root $PSScriptRoot
        if (-not $sel) {
            Write-Host ''
            Write-Host '바꿀 프로필을 고르지 못했습니다.' -ForegroundColor Red
            Write-Host '프로필이 하나도 없다면 먼저 start.bat 으로 만드세요.' -ForegroundColor Yellow
            exit 1
        }
        $slotName      = $sel.Name
        $ContainerPath = $sel.Path
    }

    $TmpPath = "$ContainerPath.tmp"
    $BakPath = "$ContainerPath.bak"

    if (-not (Test-Path -LiteralPath $ContainerPath)) {
        Write-Host "컨테이너가 없습니다: $ContainerPath" -ForegroundColor Red
        Write-Host '먼저 start.bat 으로 최초 설정을 하세요.' -ForegroundColor Red
        exit 1
    }

    Write-Host ''
    Write-Host "대상 프로필: $slotName" -ForegroundColor Cyan
    Write-Host ''

    # 최소 자릿수 규칙은 없다. 빈 입력만 막는다 (에코가 없어 Enter 오타와 구분할 수 없다).
    $oldPw = Read-Host '기존 비밀번호' -AsSecureString
    if ($oldPw.Length -eq 0) {
        Write-Host '아무것도 입력되지 않았습니다. 중단합니다.' -ForegroundColor Red
        exit 1
    }

    $new1 = Read-Host '새 비밀번호' -AsSecureString
    if ($new1.Length -eq 0) {
        Write-Host '새 비밀번호에 아무것도 입력되지 않았습니다. 중단합니다.' -ForegroundColor Red
        exit 1
    }
    $new2 = Read-Host '새 비밀번호 확인' -AsSecureString

    if (-not (Test-LPPasswordMatch $new1 $new2)) {
        Write-Host '두 비밀번호가 다릅니다. 아무것도 변경하지 않았습니다.' -ForegroundColor Red
        exit 1
    }

    if (Test-Path -LiteralPath $TmpPath) { Remove-Item -LiteralPath $TmpPath -Force }

    Write-Host ''
    Write-Host '재암호화 중... (키 유도 때문에 수 초)'

    if (-not (Convert-ContainerPassword -InFile $ContainerPath -OutFile $TmpPath `
                                        -OldPassword $oldPw -NewPassword $new1)) {
        Write-Host ''
        Write-Host '기존 비밀번호가 틀렸습니다. 아무것도 변경하지 않았습니다.' -ForegroundColor Red
        if (Test-Path -LiteralPath $TmpPath) { Remove-Item -LiteralPath $TmpPath -Force }
        exit 1
    }

    # 새 비밀번호로 정말 열리는지 확인한 뒤에야 기존 파일을 건드린다.
    # 이 연산이 잘못되면 로그인 상태를 영구히 잃는 유일한 지점이므로 검증을 한 번 더 한다.
    Write-Host '새 비밀번호로 열리는지 확인 중...'
    $newHeader = Get-LPContainerHeader -Path $TmpPath
    $newKeys   = New-LPKeySet -Password $new1 -Salt $newHeader.Salt -Iterations $newHeader.Iterations

    if (-not (Test-LPContainer -Path $TmpPath -KeySet $newKeys)) {
        Remove-Item -LiteralPath $TmpPath -Force -ErrorAction SilentlyContinue
        Write-Host '검증 실패. 기존 파일을 그대로 두었습니다.' -ForegroundColor Red
        exit 1
    }

    # 원자적 교체 + 한 세대 백업 (이전 비밀번호로 열리는 파일이 .bak 에 남는다)
    if (Test-Path -LiteralPath $BakPath) { Remove-Item -LiteralPath $BakPath -Force }
    Move-Item -LiteralPath $ContainerPath -Destination $BakPath
    Move-Item -LiteralPath $TmpPath -Destination $ContainerPath

    Write-Host ''
    Write-Host '비밀번호를 변경했습니다.' -ForegroundColor Green
    Write-Host ''
    Write-Host "주의: $BakPath 는 아직 '기존 비밀번호'로 열립니다." -ForegroundColor Yellow
    Write-Host '      기존 비밀번호가 노출되어서 바꾸는 것이라면 이 백업 파일을 지우세요.' -ForegroundColor Yellow
    exit 0
}
catch {
    Write-Host ''
    Write-Host "오류: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host '교체는 원자적으로만 이루어지므로 기존 컨테이너는 안전합니다.' -ForegroundColor Yellow
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "이 내용은 $(Join-Path $PSScriptRoot 'run-log.txt') 에도 남았습니다." -ForegroundColor DarkGray
    exit 1
}
finally {
    Stop-LPLog
}
