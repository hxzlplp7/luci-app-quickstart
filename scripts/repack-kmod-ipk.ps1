param(
    [Parameter(Mandatory = $true)]
    [string]$InputIpk,

    [Parameter(Mandatory = $true)]
    [string]$KernelDependency,

    [Parameter(Mandatory = $true)]
    [string]$OutputIpk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonScript = Join-Path $scriptDir "repack_kmod_ipk.py"

python $pythonScript `
    --input-ipk ([System.IO.Path]::GetFullPath($InputIpk)) `
    --kernel-dependency $KernelDependency `
    --output-ipk ([System.IO.Path]::GetFullPath($OutputIpk))
