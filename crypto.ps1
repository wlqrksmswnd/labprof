<#
  crypto.ps1 - 암호화 컨테이너 (AES-256-CBC + HMAC-SHA256, encrypt-then-MAC)

  사용법:  . "$PSScriptRoot\crypto.ps1"   (dot-source)

  컨테이너 형식
    "LABPROF1"(8B) | iterations(4B, little-endian) | salt(16B) | iv(16B) | ciphertext | HMAC-SHA256(32B)

    MAC은 자기 자신을 뺀 앞쪽 전부를 덮는다. magic과 iterations까지 포함되므로
    헤더를 건드리는 변조도 검증에서 걸린다.

  이 환경(Windows PowerShell 5.1 / .NET Framework 4.8)에서 확인한 제약
    - AesGcm 없음                          -> CBC + HMAC을 손으로 조합
    - CryptographicOperations 없음         -> 상수 시간 비교를 직접 구현
    - Rfc2898DeriveBytes SHA256 오버로드 O -> 반드시 명시할 것. 기본값은 SHA1이다.
#>

Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:LP_Magic      = [Text.Encoding]::ASCII.GetBytes('LABPROF1')
$script:LP_SaltSize   = 16
$script:LP_IvSize     = 16
$script:LP_MacSize    = 32
$script:LP_HeaderSize = 44        # 8 + 4 + 16 + 16
$script:LP_Iterations = 400000    # 이 PC 기준 약 1.8초. 헤더에 기록되므로 나중에 올려도 기존 파일은 계속 열린다.
$script:LP_IterMin    = 1000
$script:LP_IterMax    = 4000000   # 왜 상한이 필요한지는 Get-LPContainerHeader 주석 참고
$script:LP_ChunkSize  = 1MB


function ConvertTo-LPPasswordBytes {
    <#
      SecureString -> UTF-8 바이트. 중간에 관리되는 String을 만들지 않는다.
      String으로 바꾸면 GC될 때까지 평문이 메모리에 남고 우리가 지울 수단이 없다.

      반환은 반드시 ,$bytes 로 한다. 그냥 반환하면 PowerShell 이 배열을 파이프라인으로
      풀어 버려서 (a) 결과가 byte[] 가 아니라 object[] 로 재조립되고, (b) 원소가 하나뿐일
      때는 배열이 아예 사라져 [byte] 하나가 나온다. 그러면 호출부의 $pw.Length 가
      StrictMode 에서 터진다. "1바이트 비밀번호" 는 ASCII 한 글자를 뜻하므로,
      최소 자릿수 규칙이 없어진 지금은 실제로 들어올 수 있는 입력이다.
    #>
    param([Parameter(Mandatory)][Security.SecureString]$Password)

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($Password)
    try {
        $uni = New-Object byte[] ($Password.Length * 2)
        [Runtime.InteropServices.Marshal]::Copy($ptr, $uni, 0, $uni.Length)
        try {
            $utf8 = [Text.Encoding]::Convert([Text.Encoding]::Unicode, [Text.Encoding]::UTF8, $uni)
            return ,$utf8
        }
        finally { [Array]::Clear($uni, 0, $uni.Length) }
    }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeCoTaskMemUnicode($ptr) }
}


function Test-LPBytesEqual {
    # 상수 시간 비교. .NET Framework 4.8에는 CryptographicOperations.FixedTimeEquals가 없다.
    param([byte[]]$A, [byte[]]$B)

    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    return ($diff -eq 0)
}


function Test-LPPasswordMatch {
    # 새 비밀번호 확인 입력용
    param([Security.SecureString]$A, [Security.SecureString]$B)

    $ba = $null; $bb = $null
    try {
        # [byte[]] 로 못 박는다. ConvertTo-LPPasswordBytes 가 이미 배열을 온전히 돌려주지만,
        # 한 글자 비밀번호에서 조용히 [byte] 하나로 무너지는 일이 여기서 다시 나면 안 된다.
        [byte[]]$ba = ConvertTo-LPPasswordBytes $A
        [byte[]]$bb = ConvertTo-LPPasswordBytes $B
        return (Test-LPBytesEqual $ba $bb)
    }
    finally {
        if ($ba) { [Array]::Clear($ba, 0, $ba.Length) }
        if ($bb) { [Array]::Clear($bb, 0, $bb.Length) }
    }
}


function Test-LPPasswordCharset {
    <#
      영어 대소문자 + 숫자만으로 되어 있는지 본다. 통과하면 $true, 아니면 $false (던지지 않는다).

      SecureString을 String으로 바꾸지 않고 UTF-8 바이트에서 판정한다. 정규식(-match)을 쓰려면
      String이 필요하므로 쓰지 않는다 - ConvertTo-LPPasswordBytes 주석에 있는 이유 그대로다.

      바이트로 봐도 판정은 정확하다. ASCII 영숫자는 UTF-8에서 한 바이트로 그대로 나오고,
      UTF-8은 ASCII가 아닌 문자를 전부 0x80 이상의 바이트로만 표현한다. 그래서
      "모든 바이트가 0x30-0x39 / 0x41-0x5A / 0x61-0x7A"는 "모든 문자가 영숫자"와 같은 말이다.
      한글·공백·기호는 물론이고 짝 없는 서로게이트(U+FFFD로 바뀌어 0xEF 0xBF 0xBD)도 걸린다.

      정책 자체는 여기서 강제하지 않는다. 이 함수는 판정만 하고, 거절은 진입점이 한다.
      New-LPKeySet과 Convert-ContainerPassword가 이 검사를 부르지 않는 것은 의도다 -
      부르면 옛 비밀번호로 만든 기존 컨테이너를 열 수 없게 된다.
    #>
    param([Parameter(Mandatory)][Security.SecureString]$Password)

    $pw = $null
    try {
        [byte[]]$pw = ConvertTo-LPPasswordBytes $Password   # 한 글자여도 byte[] 로 유지된다
        if ($pw.Length -eq 0) { return $false }
        foreach ($b in $pw) {
            if (-not (($b -ge 0x30 -and $b -le 0x39) -or
                      ($b -ge 0x41 -and $b -le 0x5A) -or
                      ($b -ge 0x61 -and $b -le 0x7A))) { return $false }
        }
        return $true
    }
    finally {
        # if ($pw) 로 쓰지 않는다. 원소가 하나이고 그 값이 0이면 배열 전체가 $false로 평가되어
        # zeroize를 건너뛴다. 여기서는 실제로 한 바이트 비밀번호가 들어올 수 있다.
        if ($null -ne $pw -and $pw.Length -gt 0) { [Array]::Clear($pw, 0, $pw.Length) }
    }
}


function New-LPKeySet {
    <#
      비밀번호 + salt -> 암호화 키(32B) + MAC 키(32B)

      PBKDF2가 1.8초쯤 걸리므로 한 세션에서 한 번만 유도해서 복호화와 재암호화에 같이 쓴다.
      그래서 재암호화 때는 기존 salt를 그대로 유지하고 IV만 새로 만든다. 같은 비밀번호로
      같은 컨테이너를 다시 쓰는 것이므로 salt 유지는 안전하다. salt의 역할은 서로 다른
      컨테이너/비밀번호에 대한 사전 계산을 막는 것이지 매 저장마다 달라지는 것이 아니다.
    #>
    param(
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [byte[]]$Salt,
        [int]$Iterations = $script:LP_Iterations
    )

    if (-not $Salt) {
        $Salt = New-Object byte[] $script:LP_SaltSize
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($Salt) } finally { $rng.Dispose() }
    }

    [byte[]]$pw = ConvertTo-LPPasswordBytes $Password   # 한 글자 비밀번호도 byte[] 로 유지
    try {
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes(
                    $pw, $Salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $both = $kdf.GetBytes(64)
            $enc = New-Object byte[] 32; [Array]::Copy($both, 0,  $enc, 0, 32)
            $mac = New-Object byte[] 32; [Array]::Copy($both, 32, $mac, 0, 32)
            [Array]::Clear($both, 0, $both.Length)
            return [pscustomobject]@{ Enc = $enc; Mac = $mac; Salt = $Salt; Iterations = $Iterations }
        }
        finally { $kdf.Dispose() }
    }
    finally { [Array]::Clear($pw, 0, $pw.Length) }
}


function Get-LPContainerHeader {
    # 비밀번호 없이 읽을 수 있는 부분. 어떤 salt/반복횟수로 키를 유도해야 하는지 알려준다.
    param([Parameter(Mandatory)][string]$Path)

    $fs = [IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt ($script:LP_HeaderSize + $script:LP_MacSize)) {
            throw "컨테이너 파일이 너무 작습니다. 손상되었거나 컨테이너가 아닙니다: $Path"
        }

        $h = New-Object byte[] $script:LP_HeaderSize
        if ($fs.Read($h, 0, $h.Length) -ne $h.Length) { throw "헤더를 읽지 못했습니다: $Path" }

        for ($i = 0; $i -lt 8; $i++) {
            if ($h[$i] -ne $script:LP_Magic[$i]) { throw "컨테이너 형식이 아닙니다: $Path" }
        }

        # 이 상한을 지우지 말 것. MAC 이 헤더까지 덮으므로 "변조는 어차피 걸린다"고 생각하기
        # 쉽지만, 키 유도는 MAC 검증보다 **먼저** 돈다. 공용 폴더에 있는 남의 컨테이너에서
        # 이 4바이트만 크게 고쳐 두면, 그 사람은 비밀번호를 넣고 몇 분을 기다린 뒤에야
        # "비밀번호가 틀렸습니다"를 보게 된다 (= 파일이 깨진 줄 안다).
        $iter = [BitConverter]::ToInt32($h, 8)
        if ($iter -lt $script:LP_IterMin -or $iter -gt $script:LP_IterMax) {
            throw "헤더의 반복 횟수가 비정상입니다 ($iter). 파일이 손상된 것 같습니다."
        }

        $salt = New-Object byte[] $script:LP_SaltSize; [Array]::Copy($h, 12, $salt, 0, $script:LP_SaltSize)
        $iv   = New-Object byte[] $script:LP_IvSize;   [Array]::Copy($h, 28, $iv,   0, $script:LP_IvSize)

        return [pscustomobject]@{ Iterations = $iter; Salt = $salt; IV = $iv; Length = $fs.Length }
    }
    finally { $fs.Dispose() }
}


function Get-LPFileMac {
    # 파일 앞쪽 $Length 바이트에 대한 HMAC-SHA256. 스트리밍이므로 크기와 무관하게 메모리를 안 먹는다.
    param([string]$Path, [byte[]]$MacKey, [long]$Length)

    $hmac = [Security.Cryptography.HMACSHA256]::new($MacKey)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf  = New-Object byte[] $script:LP_ChunkSize
            $left = $Length
            while ($left -gt 0) {
                $want = [int][Math]::Min([long]$buf.Length, $left)
                $n = $fs.Read($buf, 0, $want)
                if ($n -le 0) { throw "MAC 계산 중 파일이 예상보다 짧습니다: $Path" }
                [void]$hmac.TransformBlock($buf, 0, $n, $null, 0)
                $left -= $n
            }
            [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            return $hmac.Hash
        }
        finally { $fs.Dispose() }
    }
    finally { $hmac.Dispose() }
}


function Protect-LPFile {
    <#
      파일 하나를 컨테이너로 암호화한다. IV는 매번 새로 만든다.

      MAC은 다 쓴 파일을 되읽지 않고 **쓰는 도중에** 계산한다. HashAlgorithm은
      ICryptoTransform이고 그 TransformBlock이 입력을 출력 버퍼에 그대로 복사하므로,
      CryptoStream($out, $hmac, Write)는 바이트를 통과시키면서 HMAC을 누적한다.

      읽기 패스가 하나 사라져서 저장이 빨라지는 것보다 중요한 이유가 있다. 되읽어서
      계산하면 MAC이 "디스크에서 다시 읽은 바이트"에 걸리므로, 쓰다가 한 바이트가
      깨져도 그 깨진 바이트 위에 MAC이 씌워지고 직후의 Test-LPContainer까지 통과한다
      (같은 손상을 다시 읽어 같은 MAC이 나온다). 손상은 다음 수업에 압축을 풀 때야
      드러난다. 쓰면서 계산하면 MAC은 "쓰려고 한 바이트"에 묶이고, Test-LPContainer의
      읽기가 비로소 진짜 디스크 왕복 검증이 된다. 순서를 되돌리지 말 것.

      출력 바이트는 되읽던 때와 완전히 같다 (MAC 범위도 헤더+암호문 전체 그대로).
    #>
    param(
        [Parameter(Mandatory)][string]$InFile,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][psobject]$KeySet
    )

    $iv = New-Object byte[] $script:LP_IvSize
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($iv) } finally { $rng.Dispose() }

    $mac  = $null
    $hmac = [Security.Cryptography.HMACSHA256]::new($KeySet.Mac)
    try {
        $aes = [Security.Cryptography.Aes]::Create()
        try {
            $aes.KeySize = 256
            $aes.Mode    = [Security.Cryptography.CipherMode]::CBC
            $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
            $aes.Key     = $KeySet.Enc
            $aes.IV      = $iv

            $out = [IO.File]::Create($OutFile)
            try {
                # 이 스트림에 쓴 바이트는 $out 으로 그대로 흘러가면서 HMAC에 들어간다.
                $macStream = New-Object Security.Cryptography.CryptoStream(
                                $out, $hmac, [Security.Cryptography.CryptoStreamMode]::Write)
                try {
                    $macStream.Write($script:LP_Magic, 0, 8)
                    $macStream.Write([BitConverter]::GetBytes([int]$KeySet.Iterations), 0, 4)
                    $macStream.Write($KeySet.Salt, 0, $script:LP_SaltSize)
                    $macStream.Write($iv, 0, $script:LP_IvSize)

                    $encryptor = $aes.CreateEncryptor()
                    try {
                        $cs = New-Object Security.Cryptography.CryptoStream(
                                    $macStream, $encryptor, [Security.Cryptography.CryptoStreamMode]::Write)
                        $in = [IO.File]::OpenRead($InFile)
                        try {
                            $buf = New-Object byte[] $script:LP_ChunkSize
                            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $cs.Write($buf, 0, $n) }
                            $cs.FlushFinalBlock()
                        }
                        # 안쪽을 닫으면 $macStream -> $out 까지 연쇄로 닫히고, 그때 HMAC이 확정된다.
                        finally { $in.Dispose(); $cs.Dispose() }
                    }
                    finally { $encryptor.Dispose() }
                }
                finally { $macStream.Dispose() }   # 이미 닫혀 있어도 무해하다
            }
            finally { $out.Dispose() }
        }
        finally { $aes.Dispose() }

        # $hmac.Hash 는 FlushFinalBlock 이 돈 뒤에만 값이 있다. 위에서 스트림을 다 닫았으므로 지금은 있다.
        $mac = $hmac.Hash
    }
    finally { $hmac.Dispose() }

    # encrypt-then-MAC: 지금까지 쓴 전부를 덮는 MAC을 뒤에 붙인다.
    $fs = [IO.File]::Open($OutFile, [IO.FileMode]::Append, [IO.FileAccess]::Write)
    try { $fs.Write($mac, 0, $mac.Length) } finally { $fs.Dispose() }
}


function Unprotect-LPFile {
    <#
      컨테이너를 파일 하나로 복호화한다.

      반환값:  $true  = 성공
               $false = MAC 검증 실패 (비밀번호가 틀렸거나 파일이 변조/손상됨)

      MAC을 먼저 검증하고 통과했을 때만 복호화한다. 실패하면 출력 파일을 만들지 않는다.
    #>
    param(
        [Parameter(Mandatory)][string]$InFile,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][psobject]$KeySet,
        [Parameter(Mandatory)][psobject]$Header
    )

    $cipherLen = $Header.Length - $script:LP_HeaderSize - $script:LP_MacSize
    if ($cipherLen -le 0) { throw "컨테이너가 손상되었습니다 (본문이 비어 있음): $InFile" }

    # 1) MAC 검증
    $expected = Get-LPFileMac -Path $InFile -MacKey $KeySet.Mac -Length ($Header.Length - $script:LP_MacSize)

    $stored = New-Object byte[] $script:LP_MacSize
    $fs = [IO.File]::OpenRead($InFile)
    try {
        [void]$fs.Seek(-$script:LP_MacSize, [IO.SeekOrigin]::End)
        if ($fs.Read($stored, 0, $script:LP_MacSize) -ne $script:LP_MacSize) {
            throw "MAC을 읽지 못했습니다: $InFile"
        }
    }
    finally { $fs.Dispose() }

    if (-not (Test-LPBytesEqual $expected $stored)) { return $false }

    # 2) 검증 통과 -> 복호화
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.KeySize = 256
        $aes.Mode    = [Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key     = $KeySet.Enc
        $aes.IV      = $Header.IV

        $in = [IO.File]::OpenRead($InFile)
        try {
            [void]$in.Seek($script:LP_HeaderSize, [IO.SeekOrigin]::Begin)

            $out = [IO.File]::Create($OutFile)
            try {
                $decryptor = $aes.CreateDecryptor()
                try {
                    $cs = New-Object Security.Cryptography.CryptoStream(
                                $out, $decryptor, [Security.Cryptography.CryptoStreamMode]::Write)
                    try {
                        $buf  = New-Object byte[] $script:LP_ChunkSize
                        $left = $cipherLen
                        while ($left -gt 0) {
                            $want = [int][Math]::Min([long]$buf.Length, $left)
                            $n = $in.Read($buf, 0, $want)
                            if ($n -le 0) { throw "복호화 중 파일이 예상보다 짧습니다: $InFile" }
                            $cs.Write($buf, 0, $n)
                            $left -= $n
                        }
                        $cs.FlushFinalBlock()
                    }
                    finally { $cs.Dispose() }
                }
                finally { $decryptor.Dispose() }
            }
            finally { $out.Dispose() }
        }
        finally { $in.Dispose() }
    }
    finally { $aes.Dispose() }

    return $true
}


function Test-LPContainer {
    <#
      복호화하지 않고 MAC만 검증한다. 방금 만든 컨테이너가 정말 열리는지 확인하는 용도.
      이미 유도해 둔 KeySet을 쓰므로 PBKDF2를 다시 돌리지 않아 빠르다.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][psobject]$KeySet
    )

    $header   = Get-LPContainerHeader -Path $Path
    $expected = Get-LPFileMac -Path $Path -MacKey $KeySet.Mac -Length ($header.Length - $script:LP_MacSize)

    $stored = New-Object byte[] $script:LP_MacSize
    $fs = [IO.File]::OpenRead($Path)
    try {
        [void]$fs.Seek(-$script:LP_MacSize, [IO.SeekOrigin]::End)
        [void]$fs.Read($stored, 0, $script:LP_MacSize)
    }
    finally { $fs.Dispose() }

    return (Test-LPBytesEqual $expected $stored)
}


function New-LPTempPath {
    param([string]$Extension = '.zip')
    Join-Path $env:TEMP ('lp-' + [Guid]::NewGuid().ToString('N') + $Extension)
}


function Remove-LPStaleStaging {
    <#
      비정상 종료로 남은 스테이징 zip 을 지운다. 지운 개수를 돌려준다.

      Protect-Container / Unprotect-Container 는 프로필 전체를 %TEMP% 에 평문 zip 으로
      한 번 펼친다. 정상 경로에서는 finally 가 지우지만, 콘솔 창을 X 로 닫거나 전원이
      나가면 그 평문이 남는다. 작업 폴더를 미리 치우는 것과 똑같은 이유로 다음 사람이
      시작하기 전에 치운다 - 남는 것이 "남의 로그인된 프로필"이기 때문이다.

      이름을 정규식으로 좁힌다. New-LPTempPath 가 만드는 형태만 지우고, 같은 폴더에
      있는 남의 lp-메모.zip 같은 파일은 건드리지 않는다.

      지우지 못해도 중단시키지 않는다 (호출하는 쪽 판단). 작업 폴더와 달리 이건
      "그 위에서 시작하는" 위험이 아니라 그냥 남아 있는 것이다.
    #>
    param([string]$StageDir = $env:TEMP)

    if (-not $StageDir -or -not (Test-Path -LiteralPath $StageDir)) { return 0 }

    $stale = @(
        Get-ChildItem -LiteralPath $StageDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^lp-[0-9a-f]{32}\.zip$' }
    )

    $removed = 0
    foreach ($f in $stale) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $removed++
        }
        catch {
            Write-Host "경고: 남은 임시 파일을 지우지 못했습니다: $($f.FullName)" -ForegroundColor Yellow
            Write-Host '       재부팅하면 C: 드라이브가 초기화되므로 함께 사라집니다.' -ForegroundColor Yellow
        }
    }

    return $removed
}


function Protect-Container {
    # 폴더 -> zip -> 암호화. 압축 후 암호화 순서다 (암호문은 압축이 안 되므로 반대로 하면 의미가 없다).
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][psobject]$KeySet
    )

    $zip = New-LPTempPath
    try {
        [IO.Compression.ZipFile]::CreateFromDirectory(
            $SourceDir, $zip, [IO.Compression.CompressionLevel]::Fastest, $false)
        Protect-LPFile -InFile $zip -OutFile $OutFile -KeySet $KeySet
    }
    finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    }
}


function Unprotect-Container {
    # 암호화 -> zip -> 폴더.  $false를 반환하면 비밀번호가 틀렸거나 파일이 손상된 것이다.
    param(
        [Parameter(Mandatory)][string]$InFile,
        [Parameter(Mandatory)][string]$DestDir,
        [Parameter(Mandatory)][psobject]$KeySet,
        [Parameter(Mandatory)][psobject]$Header
    )

    $zip = New-LPTempPath
    try {
        if (-not (Unprotect-LPFile -InFile $InFile -OutFile $zip -KeySet $KeySet -Header $Header)) {
            return $false
        }

        if (Test-Path -LiteralPath $DestDir) { Remove-Item -LiteralPath $DestDir -Recurse -Force }
        [void](New-Item -ItemType Directory -Path $DestDir -Force)
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $DestDir)
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    }
}


function Convert-ContainerPassword {
    <#
      컨테이너의 비밀번호를 교체한다. 압축을 풀 필요가 없으므로 zip 바이트 그대로 재암호화한다.
      비밀번호가 바뀌므로 salt도 새로 만든다 (New-LPKeySet에 -Salt를 주지 않는다).

      반환값: $true = 성공,  $false = 기존 비밀번호가 틀림 (이때 $OutFile은 만들어지지 않는다)
    #>
    param(
        [Parameter(Mandatory)][string]$InFile,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][Security.SecureString]$OldPassword,
        [Parameter(Mandatory)][Security.SecureString]$NewPassword
    )

    $header  = Get-LPContainerHeader -Path $InFile
    $oldKeys = New-LPKeySet -Password $OldPassword -Salt $header.Salt -Iterations $header.Iterations

    $zip = New-LPTempPath
    try {
        if (-not (Unprotect-LPFile -InFile $InFile -OutFile $zip -KeySet $oldKeys -Header $header)) {
            return $false
        }
        $newKeys = New-LPKeySet -Password $NewPassword
        Protect-LPFile -InFile $zip -OutFile $OutFile -KeySet $newKeys
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
    }
}
