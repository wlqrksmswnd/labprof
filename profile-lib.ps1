<#
  profile-lib.ps1 - Chrome 프로필을 다루는 부분

  lab-profile.ps1 이 dot-source 한다. 이렇게 분리해 둔 이유는 종료 대기와
  원자적 저장 같은 까다로운 로직을 Chrome을 실제로 띄우지 않고도
  따로 불러 시험할 수 있게 하기 위해서다.

  사용법:  . "$PSScriptRoot\crypto.ps1"; . "$PSScriptRoot\profile-lib.ps1"
#>


# 재압축 전에 지울 캐시성 폴더 (프로필 루트 기준 상대 경로).
# Chrome이 알아서 다시 만들거나 다시 내려받는 것만 넣는다. 수백 MB -> 수십 MB로 줄어
# 매 수업 왕복이 몇 초로 끝난다.
#
# 로그인 상태가 들어있는 것들은 절대 넣지 않는다:
#   Local State, Default\Preferences, Default\Network\Cookies,
#   Default\Local Storage, Default\Session Storage, Default\IndexedDB
$script:LP_CacheDirs = @(
    'Default\Cache'
    'Default\Code Cache'
    'Default\GPUCache'
    'Default\DawnCache'
    'Default\DawnGraphiteCache'
    'Default\DawnWebGPUCache'
    'Default\GrShaderCache'
    'Default\ShaderCache'
    'Default\Media Cache'
    'Default\Application Cache'
    'Default\blob_storage'
    'Default\JumpListIcons'
    'Default\JumpListIconsOld'
    'Default\Service Worker\CacheStorage'
    'Default\Service Worker\ScriptCache'
    'Default\optimization_guide_hint_cache_store'
    'Default\optimization_guide_model_metadata_store'
    'GrShaderCache'
    'ShaderCache'
    'GraphiteDawnCache'
    'Crashpad'
    'component_crx_cache'
    'extensions_crx_cache'
    'optimization_guide_model_store'
    'FileTypePolicies'
    'MEIPreload'
    'OnDeviceHeadSuggestModel'
    'PKIMetadata'
    'SSLErrorAssistant'
    'SafetyTips'
    'Subresource Filter'
    'TpcdMetadata'
    'TrustTokenKeyCommitments'
    'WidevineCdm'
    'ZxcvbnData'
    'Webstore Downloads'
    'Safe Browsing'
)


function Get-LPFullPath {
    <#
      상대 경로를 절대 경로로 만든다.

      아래 함수들은 파일이 수천 개인 트리를 다루므로 .NET 파일 API 를 직접 쓴다. 그런데
      .NET 의 Environment.CurrentDirectory 는 PowerShell 의 현재 위치와 다를 수 있어서,
      상대 경로를 그대로 넘기면 엉뚱한 폴더를 가리킨다 (지우는 함수에서는 위험하다).
      그래서 .NET 에 넘기기 전에 한 번 절대 경로로 바꾼다.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath }
    catch { return $Path }
}


function Get-LPTreeSize {
    <#
      트리에 있는 파일 크기의 합(바이트).

      Get-ChildItem -Recurse | Measure-Object 는 파일마다 PSObject 를 만든다. Chrome
      프로필은 파일이 수천 개라 그것만으로 몇 초가 든다. EnumerateFiles 는 FileInfo 에
      크기를 이미 담아 돌려주므로 파일당 추가 조회도 없다.

      권한 오류로 순회가 중간에 끊기면 거기까지의 부분 합계를 쓴다. 이 숫자는 화면에
      "몇 MB 제외" 를 찍기 위한 진단용이므로 정확도보다 비용이 중요하다.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $sum = 0L
    try {
        $di = New-Object IO.DirectoryInfo (Get-LPFullPath $Path)
        foreach ($f in $di.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $sum += $f.Length }
    }
    catch { }   # 부분 합계로 계속한다

    return $sum
}


function Remove-LPTree {
    <#
      폴더 트리를 지운다. 성공하면 $null, 실패하면 마지막 오류 메시지를 돌려준다.

      [IO.Directory]::Delete 를 먼저 쓰는 이유는 Get-LPTreeSize 와 같다 - Remove-Item
      -Recurse 는 파일마다 PSObject 를 만든다. 다만 .NET 쪽은 읽기 전용 파일과 260자
      초과 경로에서 던지므로 Remove-Item 폴백이 반드시 필요하다 (Remove-Item -Force 는
      읽기 전용 속성을 스스로 지우고, PS 5.1 이 긴 경로를 다르게 처리한다).
    #>
    param([Parameter(Mandatory)][string]$Path)

    try { [IO.Directory]::Delete((Get-LPFullPath $Path), $true); return $null }
    catch { }

    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop; return $null }
    catch { return $_.Exception.Message }
}


function Find-LPChrome {
    <#
      chrome.exe 를 찾는다. 못 찾으면 $null.

      흔한 세 위치를 먼저 보고, 없으면 레지스트리의 App Paths 를 본다. 설치 경로가
      특이한 PC 에서 도구가 시작조차 못 하는 일을 막기 위해서다 (실습실 PC 의 설치
      위치를 미리 알 수 없다).
    #>
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) |
                Where-Object { $_ }

    foreach ($root in $roots) {
        $path = Join-Path $root 'Google\Chrome\Application\chrome.exe'
        if (Test-Path -LiteralPath $path) { return $path }
    }

    $appPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe'
    )
    foreach ($key in $appPaths) {
        try {
            $prop = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
            if (-not $prop) { continue }
            $path = $prop.'(default)'
            if ($path -and (Test-Path -LiteralPath $path)) { return $path }
        }
        catch { }   # 레지스트리를 못 읽는 것은 실패가 아니다. 다음 후보로 넘어간다.
    }

    return $null
}


function Get-LPChromeCount {
    <#
      우리 프로필을 쓰는 chrome.exe 프로세스 수.

      --user-data-dir 값은 렌더러 등 자식 프로세스의 커맨드라인에도 그대로 실려 있으므로
      이 한 조건으로 우리 인스턴스 전체를 셀 수 있다. 다른 프로필로 이미 돌고 있는
      Chrome은 여기에 걸리지 않는다.

      -like 대신 .Contains()를 쓴다. 경로에 [ ] 같은 문자가 있으면 -like가 와일드카드로
      해석해 버린다.

      Get-CimInstance Win32_Process 는 커맨드라인까지 받아오느라 비싸다 (수백 ms ~ 수 초).
      이 함수는 비밀번호를 묻기도 전에 진행 중 세션 검사로 한 번 돌고, 세션 중에는
      Wait-LPChromeExit 이 2초마다 부른다. 그래서 chrome.exe 가 아예 없으면 값싼
      Get-Process 로 먼저 끝낸다 - 프로세스가 하나도 없으면 우리 마커를 가진 프로세스도
      있을 수 없으므로 판정은 달라지지 않는다.
    #>
    param([Parameter(Mandatory)][string]$Marker)

    if (-not (Get-Process -Name 'chrome' -ErrorAction SilentlyContinue)) { return 0 }

    $procs = @(
        Get-CimInstance Win32_Process -Filter "Name = 'chrome.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Marker) }
    )
    return $procs.Count
}


function Wait-LPChromeExit {
    <#
      Chrome이 완전히 끝날 때까지 기다린다.

      Start-Process -PassThru 로 받은 PID만 기다리면 안 된다. Chrome은 처음 뜬 프로세스가
      먼저 죽고 자식들이 남는 경우가 있어서, 그 PID가 사라진 시점에 압축을 시작하면
      아직 열려 있는 파일 때문에 실패한다. 그래서 프로세스 수가 0이 될 때까지 센다.

      반환값: $true  = 정상적으로 떴다가 모두 종료됨
              $false = $GraceSeconds 안에 프로세스가 한 번도 안 보였음 (실행 실패)
    #>
    param(
        [Parameter(Mandatory)][string]$Marker,
        [int]$GraceSeconds = 30,
        [int]$IntervalSeconds = 2
    )

    $seen   = $false
    $waited = 0

    while ($true) {
        $count = Get-LPChromeCount -Marker $Marker

        if ($count -gt 0) {
            if (-not $seen) {
                $seen = $true
                Write-Host 'Chrome이 실행되었습니다. 창을 모두 닫으면 자동으로 저장합니다.' -ForegroundColor Green
            }
        }
        elseif ($seen)                  { return $true }
        elseif ($waited -ge $GraceSeconds) { return $false }

        Start-Sleep -Seconds $IntervalSeconds
        if (-not $seen) { $waited += $IntervalSeconds }
    }
}


function Remove-LPProfileCaches {
    # 재압축 전 캐시 정리. 지운 용량(MB)을 돌려준다.
    param([Parameter(Mandatory)][string]$ProfileDir)

    $freedBytes = 0L

    foreach ($rel in $script:LP_CacheDirs) {
        $target = Join-Path $ProfileDir $rel
        if (-not (Test-Path -LiteralPath $target)) { continue }

        $freedBytes += Get-LPTreeSize -Path $target

        $err = Remove-LPTree -Path $target
        if ($err) {
            # 잠긴 파일 하나 때문에 저장 전체를 실패시킬 이유는 없다. 그냥 같이 압축된다.
            Write-Verbose "캐시 정리 건너뜀: $rel ($err)"
        }
    }

    return [math]::Round($freedBytes / 1MB, 1)
}


function Get-LPProfileTopDirs {
    <#
      캐시 정리 뒤에도 컨테이너에 실려 가는 큰 폴더 상위 N개를 "이름 크기MB" 문자열로 돌려준다.

      진단용이다. LP_CacheDirs 에 무엇을 더 넣어야 저장이 빨라지는지를 추측이 아니라
      실측으로 정하기 위한 것이다 - 그 목록은 로그인 상태가 걸린 denylist 여서 잘못
      넣으면 조용히 로그인이 깨진다. 그래서 먼저 로그로 크기를 본다.
      수업 로그를 두어 번 받아 판단이 끝나면 이 함수와 호출부는 지워도 된다.

      트리를 한 번만 훑고(크기는 FileInfo 에 이미 있다) 상대 경로 앞 두 조각으로 묶는다.
    #>
    param(
        [Parameter(Mandatory)][string]$ProfileDir,
        [int]$Top = 5
    )

    $sizes = @{}
    try {
        $di  = New-Object IO.DirectoryInfo (Get-LPFullPath $ProfileDir)
        $cut = $di.FullName.TrimEnd('\').Length + 1

        foreach ($f in $di.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
            $parts = $f.FullName.Substring($cut).Split('\')
            if     ($parts.Count -le 1) { $key = '(루트 파일)' }
            elseif ($parts.Count -eq 2) { $key = $parts[0] }
            else                        { $key = $parts[0] + '\' + $parts[1] }

            if ($sizes.ContainsKey($key)) { $sizes[$key] += [long]$f.Length }
            else                          { $sizes[$key]  = [long]$f.Length }
        }
    }
    catch { }   # 진단용이므로 부분 결과라도 그대로 쓴다

    return @(
        $sizes.GetEnumerator() |
            Sort-Object -Property Value -Descending |
            Select-Object -First $Top |
            ForEach-Object { "$($_.Key) $([math]::Round($_.Value / 1MB, 1))MB" }
    )
}


function Save-LPContainer {
    <#
      작업 폴더를 컨테이너로 저장한다. 원자적으로 교체하고 한 세대 백업을 남긴다.

        1) .tmp 로 새로 암호화
        2) .tmp 의 MAC을 검증  <- 이걸 통과하기 전에는 기존 파일을 절대 건드리지 않는다
        3) 기존 profile.enc -> profile.enc.bak
        4) .tmp -> profile.enc

      중간에 죽어도 profile.enc 는 항상 열리는 상태로 남는다. 최악의 경우가
      "지난번 상태로 되돌아감"이지 "전부 잃음"이 아니다.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$ContainerPath,
        [Parameter(Mandatory)][psobject]$KeySet
    )

    $tmp = "$ContainerPath.tmp"
    $bak = "$ContainerPath.bak"

    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }

    Protect-Container -SourceDir $SourceDir -OutFile $tmp -KeySet $KeySet

    if (-not (Test-LPContainer -Path $tmp -KeySet $KeySet)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw '새로 만든 컨테이너의 검증에 실패했습니다. 기존 파일은 그대로 두었습니다.'
    }

    if (Test-Path -LiteralPath $ContainerPath) {
        if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
        Move-Item -LiteralPath $ContainerPath -Destination $bak
    }
    Move-Item -LiteralPath $tmp -Destination $ContainerPath

    return [math]::Round((Get-Item -LiteralPath $ContainerPath).Length / 1MB, 1)
}


function Remove-LPWorkDir {
    # 평문 프로필 삭제. 실패해도 치명적이지 않다 - C: 이므로 재부팅 때 초기화된다.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    if (-not (Remove-LPTree -Path $Path)) { return $true }

    Write-Host "경고: 평문 프로필 폴더를 지우지 못했습니다: $Path" -ForegroundColor Yellow
    Write-Host '       재부팅하면 C: 드라이브가 초기화되므로 함께 사라집니다.' -ForegroundColor Yellow
    return $false
}
