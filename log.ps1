<#
  log.ps1 - 화면에 나온 내용을 파일로도 남긴다

  실습실 PC 는 종료되면 C: 가 초기화되므로 오류를 나중에 다시 볼 방법이 없다.
  스크립트 폴더(= D:)의 run-log.txt 에 붙여 써서, 화면을 사진으로 찍는 대신
  이 파일을 들고 나올 수 있게 한다.

  Start-Transcript 를 쓴다. Write-Host 출력은 그대로 들어간다.

  비밀번호는 기록되지 않는다. Read-Host -AsSecureString 은 입력이 화면에
  찍히지 않으므로 기록에 남을 내용 자체가 없다. 남는 것은 슬롯 이름,
  메뉴 선택, 각 단계의 안내 문구, 오류 메시지와 스택뿐이다.
  (그래도 이 파일은 같은 폴더를 쓰는 사람들이 다 볼 수 있다. 누가 언제
   어떤 프로필을 열었는지가 보인다는 뜻이다.)

  기록에 실패해도 본 작업은 그대로 계속한다. 로그가 없다고 Chrome 이
  안 열리면 주객이 전도된다.

  사용법:  . "$PSScriptRoot\log.ps1"
#>


$script:LP_LogName    = 'run-log.txt'
$script:LP_LogMaxSize = 1MB
$script:LP_LogStarted = $false


function Test-LPLogBom {
    <#
      파일이 UTF-8 BOM 으로 시작하는지.

      이게 왜 필요한가: Start-Transcript -Append 는 대상 파일에 BOM 이 없으면
      ASCII 로 기록한다 (문서에 명시된 동작이다). 그러면 이 도구의 모든 메시지가
      한글이므로 로그가 전부 ? 로 깨진다. 그래서 BOM 을 우리가 먼저 심는다.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $head = New-Object byte[] 3
            $read = $fs.Read($head, 0, 3)
            return ($read -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
        }
        finally { $fs.Dispose() }
    }
    catch { return $false }
}


function Start-LPLog {
    <#
      기록을 시작한다. 성공하면 $true, 실패해도 throw 하지 않고 $false.

      -Tag 는 로그에서 실행을 구분하는 머리말이다 (start / change-password).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Tag = ''
    )

    try {
        # Join-Path 는 없는 드라이브를 받으면 throw 한다 ($ErrorActionPreference='Stop').
        # 경로 계산까지 try 안에 두고, 공급자를 타지 않는 문자열 결합을 쓴다.
        # 이 함수는 무슨 일이 있어도 본 작업을 끌고 내려가지 않아야 한다.
        $path = [System.IO.Path]::Combine($Root, $script:LP_LogName)

        $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue

        # 한 세대만 남기고 밀어낸다. 너무 커졌거나, BOM 이 없어서 이어 쓰면
        # 한글이 깨질 파일이면 옆으로 치우고 새로 시작한다.
        if ($item -and (($item.Length -gt $script:LP_LogMaxSize) -or -not (Test-LPLogBom $path))) {
            $old = "$path.1"
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
            Move-Item -LiteralPath $path -Destination $old
        }

        if (-not (Test-Path -LiteralPath $path)) {
            [System.IO.File]::WriteAllBytes($path, [byte[]](0xEF, 0xBB, 0xBF))
        }

        Start-Transcript -LiteralPath $path -Append -Force | Out-Null
        $script:LP_LogStarted = $true

        if ($Tag) {
            Write-Host ("[{0}] {1}" -f $Tag, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
        }
        return $true
    }
    catch {
        # D: 가 읽기 전용이거나, 다른 사람의 세션이 파일을 잡고 있는 경우.
        Write-Host "(기록 파일을 열지 못했습니다: $($_.Exception.Message))" -ForegroundColor DarkGray
        Write-Host '(로그 없이 계속합니다. 오류가 나면 화면을 사진으로 남기세요.)' -ForegroundColor DarkGray
        $script:LP_LogStarted = $false
        return $false
    }
}


function Stop-LPLog {
    # 시작하지 않았으면 아무것도 하지 않는다. 실패해도 조용히 넘어간다
    # (프로세스가 끝나면 어차피 닫힌다).
    if (-not $script:LP_LogStarted) { return }
    try { Stop-Transcript | Out-Null } catch { }
    $script:LP_LogStarted = $false
}
