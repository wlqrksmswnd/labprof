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

function Write-LPBootError {
    <#
      Start-LPLog 보다 앞선 구간의 오류를 run-log.txt 에 직접 붙여 쓴다.

      그 구간에서 죽으면 transcript 가 아직 없다. 화면에만 뜨고 창을 닫으면 그걸로
      끝이며, C: 는 종료할 때 초기화되니 증거가 영구히 사라진다. 그래서 log.ps1 을
      거치지 않고 .NET 으로 직접 쓴다 - log.ps1 자체를 못 불러온 경우가 여기에
      포함되기 때문이다. 같은 이유로 이 함수는 공용 파일에 둘 수 없고,
      change-password.ps1 에 한 벌 더 있다 (공용 파일에 두면 그 파일이 없을 때 못 쓴다).

      이 함수는 예외를 내지 않는다. 기록에 실패하는 것이 원래 오류 안내를 막아서는 안 된다.
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
            # 새로 만들 때는 BOM 을 붙인다. log.ps1 은 BOM 없는 파일을 발견하면 한 세대
            # 밀어 버리고, 메모장도 BOM 이 없으면 이 파일을 CP949 로 읽어 한글이 깨진다.
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
# 여기는 Start-LPLog 보다 앞이라 transcript 가 없는 구간이다. 아래 두 가드가 그 구간을
# D: 에 남긴다. (창이 뜨기도 전에 Windows 가 실행을 막는 경우는 이것으로도 못 잡는다 -
#  그건 unblock.bat 과 collect-env 의 BlockedFiles 쪽 문제다.)
#
# 먼저 파일이 다 있는지 본다. 폴더를 D: 로 복사하다 중간에 끊긴 경우가 실제로 이 모양으로
# 나타나므로, 어느 파일이 없는지 이름을 대야 사용자가 다시 복사할 수 있다.
# 이 목록이 곧 로드 순서다 (아래에서 위로: crypto -> profile-lib -> slots).
$LibFiles = @('crypto.ps1', 'profile-lib.ps1', 'slots.ps1', 'log.ps1')

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

    $WorkDir = Join-Path $env:LOCALAPPDATA 'Temp\lp'   # 짧게 유지한다. Chrome 은 긴 경로에서 문제를 일으킨 적이 있다.
}
catch {
    # 문법 오류(BOM 이 깨져 CP949 로 읽힌 경우가 대표적)도 여기서 잡힌다.
    Write-LPBootError ("스크립트를 불러오는 중 오류가 났습니다.`r`n" +
                       "$($_.Exception.Message)`r`n$($_.ScriptStackTrace)")
    exit 1
}

# 첫 출력보다 먼저 시작해야 화면에 나온 것이 전부 파일에도 남는다.
[void](Start-LPLog -Root $PSScriptRoot -Tag 'start')


function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
}


# ── 단계별 소요 시간 ────────────────────────────────────────────────────────────
# 2차 검증 로그(run-log.txt)에는 블록의 시작/끝 시각만 있어서, 31초 중 어디가 느린지
# 알 수 없었다. 그 안에는 사람이 슬롯을 고르고 비밀번호를 치고 Chrome 을 쓴 시간까지
# 다 들어 있다. 그래서 각 단계를 직접 재서 마지막에 한 줄로 남긴다 - 다음에 무엇을
# 줄일지는 추측이 아니라 이 줄로 정한다.
#
# StrictMode 가 켜져 있으므로 미리 초기화한다. 실행되지 않은 단계는 $null 로 남고
# 출력에서 빠진다 (셋업 모드에는 '열기' 가 없다).
# Measure-Command 는 반환값을 버리므로 쓸 수 없다. Stopwatch 를 하나 만들어 재사용한다.
$swPhase = [System.Diagnostics.Stopwatch]::new()
$tKdf    = $null
$tOpen   = $null
$tCache  = $null
$tSave   = $null
$tWipe   = $null


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
        Write-Host '    다른 곳에 쓰지 않는 비밀번호를 쓰세요.'
        Write-Host '  - 영어 대소문자와 숫자만 쓸 수 있습니다 (한글, 공백, 기호는 안 됩니다)'
        Write-Host ''

        # 최소 자릿수 규칙은 없다. 빈 입력만 막는다 - 그건 자릿수 정책이 아니라 입력 실수
        # 방어다. Read-Host 는 에코가 없으므로 Enter 를 한 번 더 누른 것과 "빈 비밀번호를
        # 원한다" 를 구분할 수 없고, 통과시키면 그 컨테이너는 Enter 만으로 열린다.
        #
        # 문자 제한도 자릿수 규칙이 아니라 같은 종류의 방어다. 에코가 없어 IME(한/영)가
        # 켜져 있었는지 알 수 없고, 셋업에서는 두 번 다 같게 들어가 통과해 버린다. 다음
        # 수업에 같은 키를 눌러도 열리지 않고, 그때 잃는 것은 로그인 상태 전부다.
        # 확인 입력을 받기 전에 검사한다 - 두 번 다 치게 한 뒤 되돌리면 헛수고가 두 번이다.
        $pw1 = Read-Host '새 비밀번호' -AsSecureString
        if ($pw1.Length -eq 0) {
            Write-Host '아무것도 입력되지 않았습니다. 중단합니다.' -ForegroundColor Red
            exit 1
        }
        if (-not (Test-LPPasswordCharset $pw1)) {
            Write-Host '영어 대소문자와 숫자만 쓸 수 있습니다 (한글, 공백, 기호는 안 됩니다). 중단합니다.' -ForegroundColor Red
            Write-Host '한글 입력기(한/영)가 켜져 있지 않은지 확인하세요.' -ForegroundColor Yellow
            exit 1
        }
        $pw2 = Read-Host '새 비밀번호 확인' -AsSecureString

        if (-not (Test-LPPasswordMatch $pw1 $pw2)) {
            Write-Host '두 비밀번호가 다릅니다. 중단합니다.' -ForegroundColor Red
            exit 1
        }

        $password = $pw1
        Write-Host ''
        Write-Host '키 유도 중... (수 초)'
        $swPhase.Restart()
        $keys = New-LPKeySet -Password $password          # 새 salt 를 만든다
        $tKdf = [math]::Round($swPhase.Elapsed.TotalSeconds, 1)

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
            Write-Host '아무것도 입력되지 않았습니다. 중단합니다.' -ForegroundColor Red
            exit 1
        }

        $header = Get-LPContainerHeader -Path $ContainerPath

        Write-Host '컨테이너 여는 중... (수 초)'
        $swPhase.Restart()
        $keys = New-LPKeySet -Password $password -Salt $header.Salt -Iterations $header.Iterations
        $tKdf = [math]::Round($swPhase.Elapsed.TotalSeconds, 1)

        $swPhase.Restart()
        $opened = Unprotect-Container -InFile $ContainerPath -DestDir $WorkDir -KeySet $keys -Header $header
        $tOpen  = [math]::Round($swPhase.Elapsed.TotalSeconds, 1)

        if (-not $opened) {
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

    # 경로를 확인한 곳(Find-LPChrome)과 여기 사이에는 슬롯 선택 + 비밀번호 입력 + 키 유도가
    # 있어서 실제로 20초쯤 벌어진다. 2차 검증에서 그 사이에 Start-Process 가
    # "지정된 파일을 찾을 수 없습니다" 로 실패했고 28초 뒤 재실행은 성공했다. 부팅 직후는
    # Google 업데이터가 도는 시간대이고 Chrome 업데이트는 chrome.exe 를 실제로 교체한다 -
    # 교체되는 순간의 CreateProcess 가 정확히 그 오류다. 그래서 실행 직전에 다시 확인하고,
    # 한 번만 재시도한다. 재시도는 두 모드 모두 안전하다(컨테이너를 건드리지 않고,
    # 작업 폴더 상태도 바뀌지 않는다).
    if (-not (Test-Path -LiteralPath $chrome)) {
        Write-Host 'chrome.exe 가 방금 사라졌습니다. 다시 찾습니다...' -ForegroundColor Yellow
        $found = Find-LPChrome
        if ($found) { $chrome = $found }
    }

    # -WorkingDirectory 를 준다. 물려받은 현재 폴더가 유효하지 않은 경우도 같은 오류를
    # 내므로 그 원인을 없앤다. 단, 폴더가 실제로 있을 때만 준다 - 없는 폴더를 주면
    # Start-Process 가 "WorkingDirectory 매개 변수" 오류를 내면서 진짜 원인(exe 가 없다)을
    # 가려 버린다. exe 가 정말 사라진 경우가 바로 그 상황이다.
    $spArgs   = @{ FilePath = $chrome; ArgumentList = $chromeArgs }
    $chromeDir = Split-Path -Parent $chrome
    if ($chromeDir -and (Test-Path -LiteralPath $chromeDir -PathType Container)) {
        $spArgs['WorkingDirectory'] = $chromeDir
    }

    $launchError = $null
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Start-Process @spArgs
            $launchError = $null
            break
        }
        catch {
            $launchError = $_.Exception.Message
            if ($attempt -eq 1) {
                Write-Host "Chrome 실행이 실패했습니다. 2초 뒤 한 번 더 시도합니다. ($launchError)" -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
    }

    if ($launchError) {
        Write-Host ''
        Write-Host 'Chrome 을 실행하지 못했습니다.' -ForegroundColor Red
        Write-Host "  실행 파일  : $chrome" -ForegroundColor DarkGray
        Write-Host "  파일 존재  : $(Test-Path -LiteralPath $chrome)" -ForegroundColor DarkGray
        Write-Host "  오류       : $launchError" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host 'Chrome 자동 업데이트와 겹쳤을 수 있습니다. 30초 뒤 다시 실행해 보세요.' -ForegroundColor Yellow
        if ($isSetup) {
            Write-Host '컨테이너를 만들지 않고 종료합니다.' -ForegroundColor Red
        }
        else {
            Write-Host '기존 컨테이너를 그대로 두고 종료합니다 (저장하지 않음).' -ForegroundColor Yellow
        }
        [void](Remove-LPWorkDir -Path $WorkDir)
        exit 1
    }

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

    $swPhase.Restart()
    $freedMb = Remove-LPProfileCaches -ProfileDir $WorkDir
    $tCache  = [math]::Round($swPhase.Elapsed.TotalSeconds, 1)
    Write-Host "캐시 정리: ${freedMb}MB 제외"

    # 진단용. 컨테이너에 실려 가는 것이 무엇인지 로그에 남겨, denylist 에 무엇을 더 넣을지를
    # 실측으로 정한다. 두어 번 판단이 끝나면 이 두 줄은 지워도 된다.
    $topDirs = @(Get-LPProfileTopDirs -ProfileDir $WorkDir -Top 5)
    if ($topDirs.Count -gt 0) {
        Write-Host "남은 큰 폴더: $($topDirs -join ', ')" -ForegroundColor DarkGray
    }

    $swPhase.Restart()
    $sizeMb = Save-LPContainer -SourceDir $WorkDir -ContainerPath $ContainerPath -KeySet $keys
    $tSave  = [math]::Round($swPhase.Elapsed.TotalSeconds, 1)
    Write-Host "저장 완료: $(Split-Path -Leaf $ContainerPath) (${sizeMb}MB)" -ForegroundColor Green

    # 파일 수천 개를 지우는 동안 아무 출력이 없으면 멈춘 것처럼 보인다.
    Write-Host '평문 프로필 정리 중...' -ForegroundColor DarkGray
    $swPhase.Restart()
    [void](Remove-LPWorkDir -Path $WorkDir)
    $tWipe = [math]::Round($swPhase.Elapsed.TotalSeconds, 1)

    # 다음 단축 작업의 유일한 입력이다. CHECKLIST.md 가 이 줄을 적어 오라고 지시한다.
    # {0:0.0} 으로 자리를 고정한다. 2.0 을 "2s" 로 찍으면 로그를 눈으로 비교하기 어렵다.
    $phases = @()
    if ($null -ne $tKdf)   { $phases += ('키유도 {0:0.0}s' -f $tKdf) }
    if ($null -ne $tOpen)  { $phases += ('열기 {0:0.0}s'   -f $tOpen) }
    if ($null -ne $tCache) { $phases += ('캐시 {0:0.0}s'   -f $tCache) }
    if ($null -ne $tSave)  { $phases += ('저장 {0:0.0}s'   -f $tSave) }
    if ($null -ne $tWipe)  { $phases += ('정리 {0:0.0}s'   -f $tWipe) }
    if ($phases.Count -gt 0) {
        Write-Host ''
        Write-Host "[시간] $($phases -join '  ')" -ForegroundColor DarkGray
    }

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
