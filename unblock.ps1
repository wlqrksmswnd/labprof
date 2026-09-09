<#
  unblock.ps1 - 인터넷에서 받은 파일의 차단 표시(MOTW) 제거

  왜 필요한가:
    GitHub 에서 ZIP 으로 내려받아 풀면 모든 파일에 Zone.Identifier 라는 ADS 가 붙는다.
    Windows 는 그 표시가 있는 파일을 실행할 때마다 확인 창을 띄우는데, 그 창은
    powershell.exe 보다 먼저 뜬다. 즉 우리 코드가 한 줄도 실행되기 전이라
    run-log.txt 에 아무것도 남지 않는다. 2026-09-09 실습실에서 start.bat 과
    collect-env.bat 이 각각 첫 실행에서 한 번씩 이것에 걸렸다.

    표시는 파일 자체에 붙어 있고 파일은 D: 에 있으므로, 한 번 지우면 실습실 초기화
    후에도 지워진 상태로 남는다. 그래서 D: 로 복사한 직후 한 번만 실행하면 된다.

  이 스크립트가 고치지 못하는 것:
    백신이나 복원솔루션의 첫 실행 차단은 여기서 손댈 수 없다 (허용 기록이 C: 에
    남아 수업마다 반복된다). 둘을 가리는 방법은 collect-env.bat 을 돌려
    env-log.txt 의 BlockedFiles 줄을 보는 것이다 - 그 줄이 (없음) 인데도 창이 뜨면
    백신·정책이므로 관리자에게 예외 등록을 요청해야 한다.

  실행은 unblock.bat 으로 한다.
#>

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Get-LPBlockedNames {
    # 폴더 안에서 Zone.Identifier 가 붙어 있는 파일 이름만 돌려준다.
    # -Recurse 를 쓰지 않는다: 이 폴더는 평평한 구조이고, .git 같은 것을 훑을 이유가 없다.
    param([Parameter(Mandatory)][string]$Root)

    return @(
        Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                Get-Item -LiteralPath $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
            } |
            ForEach-Object { $_.Name } |
            Sort-Object
    )
}

Write-Host ''
Write-Host '=== 차단 표시 제거 ===' -ForegroundColor Cyan
Write-Host ''

$before = @(Get-LPBlockedNames -Root $PSScriptRoot)

if ($before.Count -eq 0) {
    Write-Host '차단된 파일이 없습니다. 그대로 start.bat 을 실행하세요.' -ForegroundColor Green
    exit 0
}

Write-Host "차단 표시가 붙은 파일 $($before.Count)개:"
foreach ($name in $before) { Write-Host "  $name" }
Write-Host ''

Get-ChildItem -LiteralPath $PSScriptRoot -File -Force -ErrorAction SilentlyContinue |
    Unblock-File -ErrorAction SilentlyContinue

$after = @(Get-LPBlockedNames -Root $PSScriptRoot)

if ($after.Count -eq 0) {
    Write-Host '차단 표시를 모두 제거했습니다.' -ForegroundColor Green
    Write-Host ''
    Write-Host 'D: 는 초기화되지 않으므로 다음 수업에도 이 상태가 유지됩니다.' -ForegroundColor DarkGray
    Write-Host '이 폴더에 파일을 새로 내려받아 넣었을 때만 다시 실행하면 됩니다.' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '그래도 확인 창이 또 뜬다면 차단 표시가 원인이 아닙니다.' -ForegroundColor Yellow
    Write-Host 'collect-env.bat 을 실행해 env-log.txt 의 BlockedFiles 줄을 확인하세요.' -ForegroundColor Yellow
    exit 0
}

Write-Host "다음 파일은 표시를 지우지 못했습니다 ($($after.Count)개):" -ForegroundColor Red
foreach ($name in $after) { Write-Host "  $name" -ForegroundColor Red }
Write-Host ''
Write-Host 'D: 가 읽기 전용이거나 파일이 다른 프로그램에 잡혀 있을 수 있습니다.' -ForegroundColor Yellow
Write-Host '파일을 우클릭 - 속성 - 맨 아래 "차단 해제" 를 직접 눌러도 됩니다.' -ForegroundColor Yellow
exit 1
