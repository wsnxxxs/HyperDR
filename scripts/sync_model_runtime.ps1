param(
  [string]$ModelRoot = "C:\Users\Ryan\Desktop\HyperDR_Model",
  [string]$RuntimeRoot = "C:\Users\Ryan\Desktop\HyperDR\HyperDR_Model"
)

$ErrorActionPreference = "Stop"
$source = (Resolve-Path -LiteralPath $ModelRoot).Path
if (-not (Test-Path -LiteralPath $source -PathType Container)) {
  throw "Model source does not exist: $ModelRoot"
}
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null

# The model repository is the source of truth. Runtime packaging receives only
# source and contract files; private datasets, checkpoints, caches and virtual
# environments are intentionally excluded.
$paths = @(
  "hyperdr_ml",
  "scripts",
  "infer_gain.py",
  "evaluate_absolute.py",
  "train.py",
  "requirements.txt",
  "README.md"
)
foreach ($relative in $paths) {
  $from = Join-Path $source $relative
  if (-not (Test-Path -LiteralPath $from)) {
    throw "Missing model source path: $from"
  }
  $to = Join-Path $RuntimeRoot $relative
  $parent = Split-Path -Parent $to
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  if ((Get-Item -LiteralPath $from).PSIsContainer) {
    Copy-Item -LiteralPath $from -Destination $parent -Recurse -Force
  } else {
    Copy-Item -LiteralPath $from -Destination $to -Force
  }
}
Write-Output "Synced HyperDR_Model source from $source to $RuntimeRoot"
