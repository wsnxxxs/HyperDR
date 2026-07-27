param(
    [Parameter(Mandatory)]
    [string]$Archive
)

$ErrorActionPreference = "Stop"
$archivePath = (Resolve-Path -LiteralPath $Archive).Path
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workRoot = Join-Path $temporaryRoot ("hyperdr-release-smoke-" + [Guid]::NewGuid().ToString("N"))
$workRoot = [IO.Path]::GetFullPath($workRoot)
if (-not $workRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to create a smoke-test workspace outside the temporary directory."
}

try {
    New-Item -ItemType Directory -Path $workRoot | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $workRoot

    $executable = Get-ChildItem -LiteralPath $workRoot -Recurse -Filter HyperDR.exe |
        Select-Object -First 1
    if (-not $executable) { throw "Release archive does not contain HyperDR.exe." }
    $bin = $executable.Directory.FullName
    foreach ($dll in @("libx265.dll", "libx265_main.dll")) {
        if (-not (Test-Path -LiteralPath (Join-Path $bin $dll) -PathType Leaf)) {
            throw "Release archive is missing the multibit x265 runtime: $dll"
        }
    }

    # A deterministic 32x32 RGB gradient. Keeping the fixture in the script
    # makes the smoke test independent of private photographs or repository
    # test data.
    $pngBase64 = "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"
    $inputImage = Join-Path $workRoot "gradient.png"
    [IO.File]::WriteAllBytes($inputImage, [Convert]::FromBase64String($pngBase64))

    foreach ($encoding in @("adaptive", "ultrahdr", "pq", "hlg", "avif-pq", "avif-hlg")) {
        $output = Join-Path $workRoot ("output-" + $encoding)
        $report = Join-Path $workRoot ("report-" + $encoding + ".json")
        New-Item -ItemType Directory -Path $output | Out-Null
        & $executable.FullName convert $inputImage --output $output `
            --encoding $encoding --overwrite --report $report
        if ($LASTEXITCODE -ne 0) {
            throw "Packaged conversion failed for encoding '$encoding' (exit $LASTEXITCODE)."
        }
        $document = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json
        if ($document.schema -ne 6 -or $document.files.Count -ne 1 -or
            -not $document.files[0].success -or -not $document.files[0].self_verified) {
            throw "Packaged conversion did not self-verify for encoding '$encoding'."
        }
    }

    Write-Host "Release smoke test passed: all six encodings converted and self-verified."
}
finally {
    if ((Test-Path -LiteralPath $workRoot) -and
        $workRoot.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
}
