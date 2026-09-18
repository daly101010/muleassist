$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$luaJitCandidates = @(
  'F:\Do Not Delete\contrib\vcpkg\installed\x64-windows-static\tools\luajit\luajit.exe',
  'F:\macroquest\contrib\vcpkg\installed\x64-windows-static\tools\luajit\luajit.exe'
)

$luaJit = $luaJitCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $luaJit) {
  throw 'LuaJIT was not found. Install MacroQuest dependencies or update tools/test-local.ps1 with the local luajit.exe path.'
}

$oldLuaPath = $env:LUA_PATH
$env:LUA_PATH = 'F:/lua/?.lua;F:/lua/?/init.lua;F:/lua/muleassist/?.lua;F:/lua/muleassist/?/init.lua;;'

try {
  Push-Location (Split-Path -Parent $repoRoot)
  & $luaJit (Join-Path $repoRoot 'tests\run_local.lua')
  exit $LASTEXITCODE
}
finally {
  Pop-Location
  $env:LUA_PATH = $oldLuaPath
}
