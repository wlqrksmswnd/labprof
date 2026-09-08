<#
  lab-profile.ps1 - 실습실 PC용 Chrome 프로필 관리자

  하는 일
    1. 쓸 프로필(슬롯)을 고르고 컨테이너 비밀번호를 한 번 받는다
    2. D:의 profile-<이름>.enc 를 C: 임시 폴더로 복호화한다
    3. 그 폴더를 --user-data-dir 로 지정해 Chrome 을 띄운다 (이미 로그인된 상태)
    4. Chrome 이 완전히 닫히면 다시 암호화해 D:에 저장하고 평문 폴더를 지운다

  평문 프로필이 D: 에 존재하는 순간은 없다. D:에는 암호화된 파일만 남는다.

  실행은 start.bat 으로 한다 (PowerShell 실행 정책 우회 포함).
  start.bat hong  처럼 슬롯 이름을 주면 선택 메뉴를 건너뛴다.
#>

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Slot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'crypto.ps1')
. (Join-Path $PSScriptRoot 'profile-lib.ps1')
. (Join-Path $PSScriptRoot 'slots.ps1')
. (Join-Path $PSScriptRoot 'log.ps1')

$WorkDir = Join-Path $env:LOCALAPPDATA 'Temp\lp'   # 짧게 유지한다. Chrome 은 긴 경로에서 문제를 일으킨 적이 있다.

# 첫 출력보다 먼저 시작해야 화면에 나온 것이 전부 파일에도 남는다.
[void](Start-LPLog -Root $PSScriptRoot -Tag 'start')


function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}


try {
    Write-Section '=== 실습실 Chrome 프로필 ==='

    $chrome = Find-LPChrome
    if (-not $chrome) {
        Write-Host 'chrome.exe 를 찾을 수 없습니다.' -ForegroundColor Red
        Write-Host '이 PC 에 Chrome 이 설치되어 있는지 확인하세요.' -ForegroundColor Red
        exit 1
    }

    # ── 진행 중인 세션 검사 ──────────────────────────────────────────────────
    # 작업 폴더는 모두가 함께 쓰는 자리다. 누가 Chrome 을 열어둔 채 자리를 비웠는데
    # 여기서 복호화를 시작하면 그 사람의 열려 있는 프로필을 부순다. 비밀번호를 묻기 전에 막는다.
    if ((Get-LPChromeCount -Marker $WorkDir) -gt 0) {
        Write-Host ''
        Write-Host '이 PC 에서 이미 프로필 세션이 실행 중입니다.' -ForegroundColor Red
        Write-Host '먼저 열려 있는 Chrome 창을 모두 닫아 그 세션을 끝내야 합니다.' -ForegroundColor Red
        Write-Host '(다른 사람이 쓰던 중일 수 있습니다. 지금 시작하면 그 사람의 프로필이 깨집니다.)' -ForegroundColor Yellow
        exit 1
    }

    # ── 남은 작업 폴더 정리 ──────────────────────────────────────────────────
    # 비정상 종료로 남은 폴더에는 앞사람의 평문 프로필이 그대로 들어 있다.
    # 복호화 성공 시점까지 미루면, 비밀번호를 틀리고 나간 사람 뒤에 남의 계정이 열린 채로 남는다.
    if (Test-Path -LiteralPath $WorkDir) {
        Write-Host '이전 세션이 남긴 임시 폴더를 정리합니다.' -ForegroundColor DarkGray
        if (-not (Remove-LPWorkDir -Path $WorkDir)) {
            Write-Host ''
            Write-Host '임시 폴더를 지우지 못했습니다. Chrome 을 실행하지 않고 종료합니다.' -ForegroundColor Red
            Write-Host '남의 프로필 위에서 시작하는 것보다 안전합니다. PC 를 재부팅한 뒤 다시 시도하세요.' -ForegroundColor Yellow
            exit 1
        }
    }

    # ── 남은 스테이징 zip 정리 ───────────────────────────────────────────────
    # 작업 폴더와 같은 이유다. 압축/해제 중간 산물이 %TEMP% 에 평문 zip 으로 남아 있으면
    # 그것도 남의 로그인된 프로필이다. 폴더만 지우고 이걸 놔두면 정리한 게 아니다.
    $staleZips = Remove-LPStaleStaging
    if ($staleZips -gt 0) {
        Write-Host "이전 세션이 남긴 임시 파일 ${staleZips}개를 정리했습니다." -ForegroundColor DarkGray
    }

    # ── 슬롯 선택 ────────────────────────────────────────────────────────────
    if ($Slot) {
        if (-not (Test-LPSlotName $Slot)) {
            Write-Host "슬롯 이름으로 쓸 수 없습니다: '$Slot'" -ForegroundColor Red
            Write-Host '영문/숫자/한글과 . _ - 만, 1~24자로 하세요.' -ForegroundColor Red
            exit 1
        }
        $slotName      = $Slot
        $ContainerPath = Get-LPSlotPath -Root $PSScriptRoot -Name $Slot
        $isSetup       = -not (Test-Path -LiteralPath $ContainerPath)

        # 인자로 받은 이름이 없을 때. 메뉴 쪽은 Resolve-LPSlotChoice 가 "없는 이름 =
        # Invalid" 로 막지만 이 경로는 그냥 셋업 모드로 들어가 버린다. 오타 하나로
        # 빈 프로필이 만들어지면 사용자는 자기 것을 잃은 줄 안다.
        # 슬롯이 하나도 없을 때는 묻지 않는다 (진짜 최초 셋업이므로).
        if ($isSetup -and (@(Get-LPSlots -Root $PSScriptRoot).Count -gt 0)) {
            if (-not (Confirm-LPNewSlot -Root $PSScriptRoot -Name $Slot)) {
                Write-Host ''
                Write-Host '취소했습니다. 아무것도 변경하지 않았습니다.' -ForegroundColor Red
                Write-Host '이름 없이 start.bat 을 실행하면 목록에서 고를 수 있습니다.' -ForegroundColor Yellow
                exit 1
            }
        }
    }
    else {
        $sel = Select-LPSlot -Root $PSScriptRoot -AllowNew
        if (-not $sel) {
            Write-Host ''
            Write-Host '프로필을 고르지 못했습니다. 아무것도 변경하지 않고 종료합니다.' -ForegroundColor Red
            exit 1
        }
        $slotName      = $sel.Name
        $ContainerPath = $sel.Path
        $isSetup       = $sel.IsNew
    }

    # ── 비밀번호 입력 + 컨테이너 열기 ────────────────────────────────────────
    if ($isSetup) {
        Write-Host ''
        Write-Host "새 프로필 '$slotName' 을 만듭니다." -ForegroundColor Yellow
        Write-Host "파일: $ContainerPath" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '새 컨테이너 비밀번호를 정하세요.'
        Write-Host '  - Google 계정 비밀번호와 다른 것으로 하세요 (둘은 아무 관계가 없습니다)'
        Write-Host '  - D: 가 공용이면 파일을 복사해 가서 오프라인으로 대입 공격할 수 있습니다.'
        Write-Host '    12자 이상, 다른 곳에 쓰지 않는 비밀번호를 쓰세요.'
        Write-Host ''

        $pw1 = Read-Host '새 비밀번호' -AsSecureString
        if ($pw1.Length -eq 0) {
            Write-Host '비밀번호가 비어 있습니다. 중단합니다.' -ForegroundColor Red
            exit 1
        }
        $pw2 = Read-Host '새 비밀번호 확인' -AsSecureString

        if (-not (Test-LPPasswordMatch $pw1 $pw2)) {
            Write-Host '두 비밀번호가 다릅니다. 중단합니다.' -ForegroundColor Red
            exit 1
        }
        if ($pw1.Length -lt 12) {
            Write-Host "경고: 비밀번호가 $($pw1.Length)자입니다. 12자 이상을 권합니다." -ForegroundColor Yellow
        }

        $password = $pw1
        Write-Host ''
        Write-Host '키 유도 중... (수 초)'
        $keys = New-LPKeySet -Password $password          # 새 salt 를 만든다

        if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
        [void](New-Item -ItemType Directory -Path $WorkDir -Force)

        Write-Host ''
        Write-Host '이제 Chrome 이 빈 프로필로 열립니다. 다음을 하세요:' -ForegroundColor Yellow
        Write-Host '  1) Google 로그인 (이메일 + 비밀번호 + 폰 2차인증)'
        Write-Host '  2) 2차인증 화면에서 "이 기기에서 다시 묻지 않음" 을 반드시 체크'
        Write-Host '     이 체크가 기기 신뢰 쿠키를 심습니다. 놓치면 매번 2차인증이 다시 뜹니다.'
        Write-Host '  3) Chrome 을 X 로 정상 종료'
    }
    else {
        Write-Host ''
        $password = Read-Host "'$slotName' 의 컨테이너 비밀번호" -AsSecureString
        if ($password.Length -eq 0) {
            Write-Host '비밀번호가 비어 있습니다. 중단합니다.' -ForegroundColor Red
            exit 1
        }

        $header = Get-LPContainerHeader -Path $ContainerPath

        Write-Host '컨테이너 여는 중... (수 초)'
        $keys = New-LPKeySet -Password $password -Salt $header.Salt -Iterations $header.Iterations

        if (-not (Unprotect-Container -InFile $ContainerPath -DestDir $WorkDir -KeySet $keys -Header $header)) {
            Write-Host ''
            Write-Host "'$slotName' 의 비밀번호가 틀렸거나 파일이 손상되었습니다." -ForegroundColor Red
            Write-Host '(다른 사람의 프로필을 고르지 않았는지도 확인하세요.)' -ForegroundColor Yellow
            Write-Host 'Chrome 을 실행하지 않고 종료합니다. 아무 파일도 변경되지 않았습니다.' -ForegroundColor Red
            exit 1
        }

        $lastSaved = (Get-Item -LiteralPath $ContainerPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        Write-Host "컨테이너 열림 (마지막 저장: $lastSaved)" -ForegroundColor Green
        Write-Host ''
        Write-Host '참고: 이 뒤에 Google 로그인 화면이 뜬다면 컨테이너 문제가 아닙니다.' -ForegroundColor DarkGray
        Write-Host '      컨테이너는 방금 정상적으로 열렸으므로, 그건 Google 쪽 세션이 만료된 것입니다' -ForegroundColor DarkGray
        Write-Host '      (계정 비밀번호를 바꿨거나 세션 유효기간이 지난 경우). 새로 로그인하면' -ForegroundColor DarkGray
        Write-Host '      종료할 때 갱신되어 저장되고 다음부터는 다시 자동으로 들어갑니다.' -ForegroundColor DarkGray
    }

    # ── Chrome 실행 ──────────────────────────────────────────────────────────
    Write-Section '--- Chrome 실행 ---'
    Write-Host "슬롯    : $slotName"
    Write-Host "chrome  : $chrome"
    Write-Host "작업폴더: $WorkDir"

    # --disable-background-mode 가 중요하다. 확장 프로그램이 "Chrome 을 닫아도 백그라운드
    # 앱 계속 실행"을 켜 두면 창을 다 닫아도 같은 --user-data-dir 로 프로세스가 살아 있고,
    # Wait-LPChromeExit 은 상한이 없으므로 영원히 기다린다.
    # 나머지 둘은 셋업 모드에서 첫 실행 안내와 "기본 브라우저로 설정" 대화상자를 없앤다
    # (임시 폴더의 프로필을 기본 브라우저로 지정해 버리는 사고를 막는다).
    $chromeArgs = "--user-data-dir=`"$WorkDir`"" +
                  ' --no-first-run --no-default-browser-check --disable-background-mode'

    Start-Process -FilePath $chrome -ArgumentList $chromeArgs

    $launched = Wait-LPChromeExit -Marker $WorkDir
    if (-not $launched) {
        Write-Host ''
        Write-Host 'Chrome 프로세스를 확인할 수 없습니다. 실행에 실패한 것 같습니다.' -ForegroundColor Red
        if ($isSetup) {
            Write-Host '컨테이너를 만들지 않고 종료합니다.' -ForegroundColor Red
        }
        else {
            Write-Host '기존 컨테이너를 그대로 두고 종료합니다 (저장하지 않음).' -ForegroundColor Yellow
        }
        [void](Remove-LPWorkDir -Path $WorkDir)
        exit 1
    }

    # ── 저장 ─────────────────────────────────────────────────────────────────
    Write-Section '--- 저장 중 ---'

    $freedMb = Remove-LPProfileCaches -ProfileDir $WorkDir
    Write-Host "캐시 정리: ${freedMb}MB 제외"

    $sizeMb = Save-LPContainer -SourceDir $WorkDir -ContainerPath $ContainerPath -KeySet $keys
    Write-Host "저장 완료: $(Split-Path -Leaf $ContainerPath) (${sizeMb}MB)" -ForegroundColor Green

    [void](Remove-LPWorkDir -Path $WorkDir)

    Write-Host ''
    Write-Host '끝났습니다. 이제 PC 를 종료해도 됩니다.' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host ''
    Write-Host "오류: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    Write-Host '기존 컨테이너 파일은 원자적으로만 교체되므로, 이 오류로 로그인 상태를' -ForegroundColor Yellow
    Write-Host '잃지는 않았습니다. 다시 실행하면 이전 상태로 열립니다.' -ForegroundColor Yellow

    # 저장 단계에서 터진 경우, 이번 세션의 변경분은 아직 이 폴더에만 있다.
    # 다음 실행이 비밀번호를 묻기 전에 지우므로 여기서 경로를 알려 줘야 한다.
    if (Test-Path -LiteralPath $WorkDir) {
        Write-Host ''
        Write-Host "작업 폴더: $WorkDir" -ForegroundColor Yellow
        Write-Host '이번 세션의 변경분(로그인 갱신 등)은 아직 이 폴더에만 있습니다.' -ForegroundColor Yellow
        Write-Host '다시 실행하면 비밀번호를 묻기 전에 지워집니다. 아까우면 먼저 복사해 두세요.' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Write-Host "이 내용은 $(Join-Path $PSScriptRoot 'run-log.txt') 에도 남았습니다." -ForegroundColor DarkGray
    exit 1
}
finally {
    Stop-LPLog
}
