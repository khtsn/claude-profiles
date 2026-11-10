# Integration checks with isolated profiles (CCP_ROOT) and a fake claude.
# Nothing here logs in, calls the usage endpoint, or touches ~/.claude: home is taken out of
# the pool first, and the test profiles are API-key profiles, which need no lookup.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'ccp.ps1'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ccp-test-' + [guid]::NewGuid())
$savedPath = $env:PATH; $savedRoot = $env:CCP_ROOT; $savedPw = $env:CCP_PASSWORD
$savedDir = $env:CLAUDE_CONFIG_DIR
$savedUser = [Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User')
function Assert($ok, $message) { if (-not $ok) { throw $message } }
function Json($text) { ($text | Out-String) | ConvertFrom-Json }
function ExitCode($arguments) {   # a real child process, the way scripts call ccp; errors go to a file
    $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"") + $arguments
    $p = Start-Process $ps -ArgumentList $list -Wait -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $fixture 'out') -RedirectStandardError (Join-Path $fixture 'err')
    $p.ExitCode
}
try {
    $null = New-Item -ItemType Directory -Path $fixture
    # fake claude: records the profile it ran under and its arguments, then fails with 7
    Set-Content -LiteralPath (Join-Path $fixture 'claude.cmd') -Value '@echo off
>"%~dp0ran" echo [%CLAUDE_CONFIG_DIR%] %*
exit /b 7'
    $env:PATH = $fixture   # only the fake claude
    $env:CCP_ROOT = $fixture
    $a = Join-Path $fixture 'profiles\a'

    & $scriptPath pool home off | Out-Null
    Assert (Test-Path (Join-Path $fixture 'profiles\.home-pool-off')) 'CCP_ROOT ignored: home pool marker is not in the fixture'

    # add: both spellings of the key flag, and the safe default mode
    & $scriptPath add a --key sk-ant-test-a | Out-Null
    & $scriptPath add b --api-key sk-ant-test-b | Out-Null
    $cfg = Get-Content -LiteralPath (Join-Path $a 'settings.json') -Raw | ConvertFrom-Json
    Assert ($cfg.env.ANTHROPIC_API_KEY -eq 'sk-ant-test-a') 'add --key did not store the key'
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'profiles\b\settings.json') -Raw | ConvertFrom-Json).env.ANTHROPIC_API_KEY -eq 'sk-ant-test-b') 'add --api-key did not store the key'
    Assert ($cfg.permissions.defaultMode -eq 'auto') 'New profiles should start in auto'
    Assert (-not $cfg.skipDangerousModePermissionPrompt) 'New profiles should not skip the bypass warning'

    # list --json
    $listed = Json (& $scriptPath list --json)
    Assert (($listed.name -join ',') -eq 'home,a,b' -and ($listed.number -join ',') -eq '1,2,3') 'List JSON order / numbers wrong'
    Assert ($listed[1].path -eq $a -and $listed[1].permissions -eq 'auto') 'List JSON path / permissions wrong'
    Assert ($listed[0].pool -eq $false -and $listed[1].pool -eq $true) 'List JSON pool wrong'
    Assert ($null -eq $listed[1].note) 'A missing note should be null in JSON'
    & $scriptPath note a team account | Out-Null
    Assert ((Json (& $scriptPath list --json))[1].note -eq 'team account') 'List JSON omitted note'
    Assert ((& $scriptPath path 2) -eq $a -and (& $scriptPath path a --env) -eq $a) 'path wrong'
    Assert (-not (& $scriptPath path home --env)) 'path --env should print nothing for home'

    # usage --json: old fields kept, shared fields added
    $u = Json (& $scriptPath usage a --json)
    Assert ($u.Count -eq 1 -and $u[0].index -eq 2 -and $u[0].profile -eq 'a' -and $u[0].status -eq 'no_login') 'Usage JSON contract changed'
    Assert ($u[0].number -eq 2 -and $u[0].path -eq $a -and $u[0].pool -eq $true) 'Usage JSON shared fields wrong'
    Assert ($u[0].available -eq $true -and $null -eq $u[0].headroom_percent) 'API-key profile should be available with unknown headroom'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'profiles\c')   # no login at all
    Assert ((Json (& $scriptPath usage c --json))[0].available -eq $false) 'A profile without a login should not be available'

    # pool + pick
    Assert ((& $scriptPath pick) -eq 'a') 'pick should return the first available pool profile'
    Assert (((& $scriptPath pick -n 5) -join ',') -eq 'a,b') 'pick -n should list every available pool profile, not home or c'
    & $scriptPath pool a off | Out-Null
    Assert ((& $scriptPath pick) -eq 'b') 'pick ignored pool off'
    Assert ((& $scriptPath list | Out-String) -match 'a \[auto\] \[pool off\]') 'list does not show pool off'
    $picked = Json (& $scriptPath pick --json)
    Assert ($picked.Count -eq 1 -and $picked[0].profile -eq 'b' -and $picked[0].available) 'pick --json wrong'
    & $scriptPath pool b off | Out-Null
    Assert ((ExitCode @('pick')) -eq 1) 'pick with an empty pool should fail'
    & $scriptPath pool b on | Out-Null

    # run: profile isolation, exit code, --perm
    & $scriptPath run a -p hi
    Assert ($LASTEXITCODE -eq 7) 'run did not pass on the exit code'
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'ran')).Trim() -eq "[$a] -p hi") 'run changed the arguments or the profile'
    Assert ($env:CLAUDE_CONFIG_DIR -eq $savedDir) 'run changed this terminal'
    & $scriptPath run a --perm readonly -p hi
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'ran')).Trim() -eq "[$a] --permission-mode plan -p hi") 'run --perm readonly wrong'
    & $scriptPath run a --perm ask -p hi
    Assert ((Get-Content -LiteralPath (Join-Path $fixture 'ran')).Trim() -eq "[$a] --permission-mode manual -p hi") 'run --perm ask wrong'
    Assert ((Get-Content -LiteralPath (Join-Path $a 'settings.json') -Raw | ConvertFrom-Json).permissions.defaultMode -eq 'auto') 'run --perm changed the saved mode'
    Remove-Item -LiteralPath (Join-Path $fixture 'ran')
    Assert ((ExitCode @('run', 'a', '--perm', 'nonsense', '-p', 'hi')) -eq 1 -and -not (Test-Path (Join-Path $fixture 'ran'))) 'run with a bad --perm should fail before starting claude'
    Assert ((ExitCode @('run', 'a', '-p', 'hi')) -eq 7) 'run exit code lost when called as a process'

    # perm: readonly is plan
    & $scriptPath perm a readonly | Out-Null
    Assert ((Json (& $scriptPath list --json))[1].permissions -eq 'plan') 'perm readonly should set plan'

    # use --local: this process only, saved setting untouched
    & $scriptPath use a --local | Out-Null
    Assert ($env:CLAUDE_CONFIG_DIR -eq $a) 'use --local did not switch this terminal'
    & $scriptPath use home --local | Out-Null
    Assert (-not $env:CLAUDE_CONFIG_DIR) 'use home --local did not clear the variable'
    Assert ([Environment]::GetEnvironmentVariable('CLAUDE_CONFIG_DIR', 'User') -eq $savedUser) 'use --local changed the saved setting'

    # backup (--password spelling, default folder under CCP_ROOT) keeps key, note and pool
    $env:CCP_PASSWORD = 'test-password'
    & $scriptPath backup --password | Out-Null
    $file = @(Get-ChildItem (Join-Path $fixture 'backups') -Filter '*.zip.enc')
    Assert ($file.Count -eq 1) 'backup --password did not write an encrypted file under CCP_ROOT'
    & $scriptPath remove a -y | Out-Null
    & $scriptPath restore $file[0].FullName --only a | Out-Null
    $back = (Json (& $scriptPath list --json))[1]
    Assert ($back.name -eq 'a' -and $back.note -eq 'team account' -and $back.pool -eq $false -and $back.permissions -eq 'plan') 'Backup lost note, pool or settings'
    'PASS: CCP_ROOT, add flags, auto default, list JSON, path, usage shared fields, pool, pick, run --perm, exit code, use --local, backup'
} finally {
    $env:PATH = $savedPath; $env:CCP_ROOT = $savedRoot; $env:CCP_PASSWORD = $savedPw
    $env:CLAUDE_CONFIG_DIR = $savedDir
    # Only remove this test's GUID directory under the system temp directory.
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path $resolved -Leaf) -like 'ccp-test-*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
