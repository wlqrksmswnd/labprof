<#
  slots.ps1 - 프로필 슬롯 (여러 사람이 한 폴더를 같이 쓰기 위한 층)

  같은 실습실 PC 를 여러 명이 쓰므로 컨테이너가 여러 개 나란히 있어야 한다.
  파일 이름에 슬롯 이름을 넣어 구분한다:

      profile-hong.enc        hong 의 컨테이너
      profile-hong.enc.bak    hong 의 직전 세대 백업
      profile-kim.enc

  암호화는 이미 사람을 구분한다 (남의 컨테이너는 비밀번호 없이 못 연다).
  여기서 더하는 것은 "여러 개 중 자기 것을 고르는" 일뿐이다.

  lab-profile.ps1 과 change-password.ps1 이 둘 다 쓴다. change-password.ps1 은
  Chrome 쪽을 전혀 안 쓰므로 profile-lib.ps1 에 넣지 않고 따로 두었다.

  사용법:  . "$PSScriptRoot\slots.ps1"
#>


$script:LP_SlotPrefix = 'profile-'
$script:LP_SlotSuffix = '.enc'

# Windows 예약 장치명. 이런 이름으로는 파일을 만들 수 없다.
$script:LP_SlotReserved = @('CON', 'PRN', 'AUX', 'NUL') +
                          (1..9 | ForEach-Object { "COM$_"; "LPT$_" })


function Test-LPSlotName {
    <#
      슬롯 이름으로 쓸 수 있는지. 파일명이 되므로 좁게 잡는다.

      - 영문/숫자/한글 + . _ -  (첫 글자는 . _ - 불가)
      - 1~24자
      - Windows 예약 장치명 불가 (확장자가 붙은 nul.txt 형태도 불가)

      경로 구분자와 와일드카드가 애초에 통과하지 못하므로 경로 조작도 같이 막힌다.
    #>
    param([string]$Name)

    if ([string]::IsNullOrEmpty($Name)) { return $false }
    if ($Name -notmatch '^[A-Za-z0-9가-힣][A-Za-z0-9가-힣._-]{0,23}$') { return $false }

    $stem = ($Name -split '\.')[0]
    if ($script:LP_SlotReserved -contains $stem.ToUpperInvariant()) { return $false }

    return $true
}


function Get-LPSlotPath {
    <#
      슬롯 이름 -> 컨테이너 경로.

      이름이 규칙에 맞지 않으면 throw 한다. 경로 조작에 대한 마지막 방어선이므로
      조용히 넘어가지 않는다.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-LPSlotName $Name)) {
        throw "슬롯 이름으로 쓸 수 없습니다: '$Name' (영문/숫자/한글과 . _ - 만, 1~24자)"
    }
    return (Join-Path $Root ($script:LP_SlotPrefix + $Name + $script:LP_SlotSuffix))
}


function Get-LPSlots {
    <#
      폴더 안의 슬롯 목록. 마지막 저장이 최근인 순서 (자주 쓰는 사람이 대개 1번).

      -Filter 대신 -like 로 거른다. 파일 시스템 필터는 8.3 짧은 이름 때문에
      profile-a.enc.bak 같은 것까지 *.enc 로 잡는 고전적인 함정이 있다.

      결과는 파이프라인으로 낱개씩 나간다. 0개/1개일 때가 있으므로 호출하는 쪽은
      반드시 @(Get-LPSlots ...) 로 감싸서 받는다.
    #>
    param([Parameter(Mandatory)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root)) { return @() }

    $pattern   = $script:LP_SlotPrefix + '*' + $script:LP_SlotSuffix
    $prefixLen = $script:LP_SlotPrefix.Length
    $suffixLen = $script:LP_SlotSuffix.Length

    $found = @(
        Get-ChildItem -LiteralPath $Root -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern } |
            ForEach-Object {
                $name = $_.Name.Substring($prefixLen, $_.Name.Length - $prefixLen - $suffixLen)

                # 메뉴에 Get-LPSlotPath 가 거부할 이름이 뜨는 일이 없게 한다
                if (Test-LPSlotName $name) {
                    [pscustomobject]@{
                        Name      = $name
                        Path      = $_.FullName
                        LastWrite = $_.LastWriteTime
                        SizeMb    = [math]::Round($_.Length / 1MB, 1)
                    }
                }
            } |
            Sort-Object LastWrite -Descending
    )

    return $found
}


function Resolve-LPSlotChoice {
    <#
      메뉴 입력 한 줄을 해석한다. 입출력이 없는 순수 함수라 단위 테스트가 된다.

      받는 것: 번호(1부터) / 슬롯 이름(대소문자 무시) / N (새로 만들기)

      반환: { Kind = 'Existing' | 'New' | 'Invalid'; Name; Path }

      못 찾은 이름은 New 가 아니라 Invalid 다. 오타 한 번에 빈 프로필이 새로
      만들어지면 사용자는 자기 것을 잃은 줄 안다. 새로 만들기는 N 으로만 한다.
    #>
    param(
        [string]$Choice,
        $Slots,
        [switch]$AllowNew
    )

    $invalid = [pscustomobject]@{ Kind = 'Invalid'; Name = $null; Path = $null }

    $list = @($Slots)
    $c    = "$Choice".Trim()

    if ($c -eq '') { return $invalid }

    if ($AllowNew -and $c -eq 'N') {
        return [pscustomobject]@{ Kind = 'New'; Name = $null; Path = $null }
    }

    if ($c -match '^[0-9]+$') {
        $i = [int]$c
        if ($i -ge 1 -and $i -le $list.Count) {
            $s = $list[$i - 1]
            return [pscustomobject]@{ Kind = 'Existing'; Name = $s.Name; Path = $s.Path }
        }
        return $invalid
    }

    $hit = @($list | Where-Object { $_.Name -eq $c })
    if ($hit.Count -eq 1) {
        return [pscustomobject]@{ Kind = 'Existing'; Name = $hit[0].Name; Path = $hit[0].Path }
    }

    return $invalid
}


function Read-LPNewSlot {
    # 새 슬롯 이름을 받는다. 성공하면 { Name; Path; IsNew=$true }, 포기하면 $null.
    param(
        [Parameter(Mandatory)][string]$Root,
        $Slots
    )

    $existing = @($Slots)

    for ($try = 1; $try -le 3; $try++) {
        Write-Host ''
        Write-Host '새 프로필 이름을 정하세요 (영문/숫자/한글, 1~24자). 예: hong, 홍길동, hong-school'
        $name = (Read-Host '이름').Trim()

        if (-not (Test-LPSlotName $name)) {
            Write-Host '쓸 수 없는 이름입니다. 영문/숫자/한글과 . _ - 만, 24자 이내로.' -ForegroundColor Yellow
            continue
        }
        if ($existing | Where-Object { $_.Name -eq $name }) {
            Write-Host "'$name' 은 이미 있습니다. 기존 것을 쓰려면 메뉴에서 고르세요." -ForegroundColor Yellow
            continue
        }

        return [pscustomobject]@{
            Name  = $name
            Path  = (Get-LPSlotPath -Root $Root -Name $name)
            IsNew = $true
        }
    }

    return $null
}


function Confirm-LPNewSlot {
    <#
      "이 이름으로 새로 만들까요?" 를 묻는다. 기본값은 거부($false).

      메뉴에서는 Resolve-LPSlotChoice 가 "없는 이름 = Invalid" 로 막아 주지만
      (오타 한 번에 빈 프로필이 만들어지면 사용자는 자기 것을 잃은 줄 안다),
      start.bat hong 처럼 인자로 받는 경로는 그 보호를 지나쳐 버린다. 그 자리에서
      쓴다. 기존 슬롯을 같이 보여 줘야 오타를 알아차릴 수 있다.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Name
    )

    $existing = @(Get-LPSlots -Root $Root)

    Write-Host ''
    Write-Host "'$Name' 이라는 프로필은 없습니다." -ForegroundColor Yellow
    if ($existing.Count -gt 0) {
        Write-Host ("이 폴더에 있는 것: " + (($existing | ForEach-Object { $_.Name }) -join ', '))
    }
    Write-Host '이름을 잘못 입력한 것이라면 여기서 멈추세요. 계속하면 빈 프로필을 새로 만들고,' -ForegroundColor Yellow
    Write-Host '처음부터 다시 로그인해야 합니다 (기존 프로필이 지워지는 것은 아닙니다).' -ForegroundColor Yellow
    Write-Host ''

    $answer = Read-Host "'$Name' 을 새로 만들까요? (y / 그 외는 취소)"
    return ("$answer".Trim() -match '^(y|yes)$')
}


function Select-LPSlot {
    <#
      슬롯 선택 화면. Resolve-LPSlotChoice 를 감싸는 입출력 껍데기다.

      반환: { Name; Path; IsNew }  /  고르지 못하면 $null

      -AllowNew 없이 슬롯이 하나도 없으면 $null 을 돌려준다
      (change-password 처럼 새로 만들 이유가 없는 쪽).
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [switch]$AllowNew
    )

    $slots = @(Get-LPSlots -Root $Root)

    if ($slots.Count -eq 0) {
        if (-not $AllowNew) { return $null }
        return (Read-LPNewSlot -Root $Root -Slots $slots)
    }

    Write-Host ''
    Write-Host '사용할 프로필을 고르세요:' -ForegroundColor Cyan
    Write-Host ''
    for ($i = 0; $i -lt $slots.Count; $i++) {
        $s = $slots[$i]
        Write-Host ('  {0}) {1,-16} (마지막 저장: {2}, {3}MB)' -f `
                    ($i + 1), $s.Name, $s.LastWrite.ToString('yyyy-MM-dd HH:mm'), $s.SizeMb)
    }
    if ($AllowNew) { Write-Host '  N) 새 프로필 만들기' }
    Write-Host ''

    for ($try = 1; $try -le 3; $try++) {
        $choice = Read-Host '선택 (번호 또는 이름)'
        $r = Resolve-LPSlotChoice -Choice $choice -Slots $slots -AllowNew:$AllowNew

        if ($r.Kind -eq 'Existing') {
            return [pscustomobject]@{ Name = $r.Name; Path = $r.Path; IsNew = $false }
        }
        if ($r.Kind -eq 'New') {
            $new = Read-LPNewSlot -Root $Root -Slots $slots
            if ($new) { return $new }
            return $null
        }

        Write-Host '목록에 없는 입력입니다. 번호나 이름을 정확히 넣으세요.' -ForegroundColor Yellow
    }

    return $null
}
