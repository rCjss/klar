# Baut Klar unter Windows. Voraussetzung: .NET-10-SDK (winget install Microsoft.DotNet.SDK.10).
#   .\build.ps1             Tests + Paket dist\Klar-<Version>-win-x64.zip
#   .\build.ps1 -Run        danach starten
#   .\build.ps1 -SelfTest   danach den Selbsttest ausführen und den Bericht anzeigen
#   .\build.ps1 -NoTest     Tests überspringen
param([switch]$Run, [switch]$SelfTest, [switch]$NoTest)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'

if (-not $NoTest) {
    dotnet test tests/Klar.Core.Tests -c Release --nologo -v q
    if ($LASTEXITCODE -ne 0) { throw 'Tests fehlgeschlagen.' }
}

$version = ([xml](Get-Content Directory.Build.props)).Project.PropertyGroup.Version
Get-Process Klar -ErrorAction SilentlyContinue | Stop-Process -Force
if (Test-Path dist) { Remove-Item dist -Recurse -Force }
dotnet publish src/Klar -c Release -o dist/Klar --nologo -v q
if ($LASTEXITCODE -ne 0) { throw 'Build fehlgeschlagen.' }
Get-ChildItem dist/Klar/runtimes -Directory | Where-Object { -not (Get-ChildItem $_.FullName -Recurse -File) } | Remove-Item -Recurse -Force
Remove-Item dist/Klar/*.pdb -ErrorAction SilentlyContinue

$zip = "dist/Klar-$version-win-x64.zip"
Compress-Archive -Path dist/Klar -DestinationPath $zip
Write-Host "Paket: $zip"

if ($SelfTest) {
    $report = Join-Path $env:TEMP 'klar-selftest.txt'
    $p = Start-Process -FilePath dist/Klar/Klar.exe -ArgumentList '--selftest', "`"$report`"" -PassThru -Wait
    Get-Content $report -Encoding UTF8
    if ($p.ExitCode -ne 0) { throw "Selbsttest: $($p.ExitCode) Fehler." }
}
if ($Run) { Start-Process dist/Klar/Klar.exe }
