# ccp - Claude Code profile switcher. Each profile is its own CLAUDE_CONFIG_DIR
# (separate login, sessions, history, settings) under .\profiles\<name>.
# "home" is the stock ~/.claude. "default" (or no name) is an alias for
# whichever profile `ccp default <name>` picked; home until you pick one.
$ErrorActionPreference = 'Stop'
trap { [Console]::Error.WriteLine("ccp: $_"); exit 1 }   # one-line errors, no stack trace
$cmd = $args[0]; $name = $args[1]   # no param(): claude flags like -p must pass through untouched
$rest = @($args | Select-Object -Skip 2)
$base = $PSScriptRoot
if ($env:CCP_ROOT) { $base = $env:CCP_ROOT }   # keep data elsewhere (also how the tests avoid real profiles)
$root = Join-Path $base 'profiles'
$defFile = Join-Path $root '.default'
$var = 'CLAUDE_CONFIG_DIR'
# Names become folder names: . @ + only singly between word chars, so emails
# work but "..", leading dots (.default) and trailing dots (Windows strips them) don't.
$nameRe = '^[\w-]+([.@+][\w-]+)*$'
# What `backup` saves per profile: the account (login + identity) and settings, not sessions/history.
$acctFiles = '.credentials.json', '.claude.json', 'settings.json', '.ccp-note', '.ccp-pool-off'
# What `backup --creds` / `restore --creds` move: the login alone.
$credFiles = @('.credentials.json')

function DefaultName {
    if (Test-Path $defFile) { (Get-Content $defFile -TotalCount 1).Trim() } else { 'home' }
}

function Names {   # in `ccp list` order; a profile's number is its position here
    @('home') + @(if (Test-Path $root) { Get-ChildItem $root -Directory | Sort-Object Name | ForEach-Object Name })
}

function Resolve($n) {   # alias, list number, or plain name -> name
    if (-not $n -or $n -eq 'default') { return DefaultName }
    if ($n -match '^\d+$') {
        $all = @(Names)
        if ([int]$n -lt 1 -or [int]$n -gt $all.Count) { throw "No profile #$n (ccp list shows 1-$($all.Count))" }
        return $all[[int]$n - 1]
    }
    $n
}

function ProfileDir($n) {
    if ($n -eq 'home') { return $null }   # null = CLAUDE_CONFIG_DIR unset = ~/.claude
    if ($n -notmatch $nameRe) { throw "Bad profile name '$n' (letters, digits, - _ and single . @ + between them, e.g. me@example.com)" }
    $dir = Join-Path $root $n
    if (-not (Test-Path $dir)) { throw "No profile '$n'. Create it: ccp add $n" }
    $dir
}

function NewProfileDir($n) {   # path for a profile that must not exist yet
    if (-not $n) { throw 'Missing new profile name' }
    if ($n -in 'home', 'default') { throw "'$n' is reserved" }
    if ($n -match '^\d+$') { throw "A name can't be only digits; numbers are list positions" }
    if ($n -notmatch $nameRe) { throw "Bad profile name '$n' (letters, digits, - _ and single . @ + between them, e.g. me@example.com)" }
    $dir = Join-Path $root $n
    if (Test-Path $dir) { throw "Profile '$n' already exists" }
    $dir
}

function NotePath($n) {   # a profile's note lives in its folder (so rename/remove/backup carry it); home's beside them
    $d = ProfileDir $n
    if ($d) { Join-Path $d '.ccp-note' } else { Join-Path $root '.home-note' }
}

function GetNote($n) {
    $f = NotePath $n
    if (Test-Path $f) { return ([IO.File]::ReadAllText($f)).Trim() }
    $null   # a real null, so JSON says null rather than {}
}

function HomeSkills($dir) {   # a new profile starts with home's own skills: copies, since links need admin rights here
    $src = Join-Path $HOME '.claude\skills'
    if (-not (Test-Path $src)) { return }
    foreach ($s in @(Get-ChildItem $src -Directory | Where-Object { $_.Name -notmatch '^\.' -and $_.Name -ne 'synced' })) {   # synced\ is claude's own, per account
        $dst = Join-Path $dir 'skills'
        New-Item -ItemType Directory -Force $dst | Out-Null
        Copy-Item -LiteralPath $s.FullName -Destination $dst -Recurse
    }
}

function ProfilePath($n) {   # like ProfileDir, but home is a real path
    $d = ProfileDir $n
    if ($d) { $d } else { Join-Path $HOME '.claude' }
}

# Pool = the profiles `ccp pick` may hand to automation. In by default; a marker file takes one out.
function PoolPath($n) {
    $d = ProfileDir $n
    if ($d) { Join-Path $d '.ccp-pool-off' } else { Join-Path $root '.home-pool-off' }
}

function InPool($n) { -not (Test-Path (PoolPath $n)) }

function Retarget($old, $new) {   # repoint this terminal and the saved setting if they were on $old
    if ([Environment]::GetEnvironmentVariable($var) -eq $old) { [Environment]::SetEnvironmentVariable($var, $new) }
    if ([Environment]::GetEnvironmentVariable($var, 'User') -eq $old) {
        [Environment]::SetEnvironmentVariable($var, $new, 'User')
    }
}

# Permission modes = permissions.defaultMode in the profile's settings.json, the key
# claude itself reads, so they apply to plain `claude` after `ccp use` as well as `ccp run`.
$modes = [ordered]@{
    bypass = 'bypassPermissions'   # no prompts at all
    auto   = 'auto'                # classifier approves safe actions, blocks risky ones
    edits  = 'acceptEdits'         # file edits without asking, prompts for the rest
    ask    = 'default'             # stock behaviour: prompt for edits and commands
    plan   = 'plan'                # read-only planning
}

function Mode($m) {   # accepts cxp's name for the read-only mode too -> a key of $modes
    if ($m -eq 'readonly') { $m = 'plan' }
    if (-not $m -or -not $modes.Contains("$m")) { throw "Unknown mode '$m'. Use: $($modes.Keys -join ', ') (readonly = plan)" }
    "$m"
}

function ConfigPath($n) { Join-Path (ProfilePath $n) 'settings.json' }

function GetPerm($cfg) {
    $m = $null
    if (Test-Path $cfg) { $m = ([IO.File]::ReadAllText($cfg) | ConvertFrom-Json).permissions.defaultMode }
    if (-not $m) { return 'claude-default' }
    foreach ($k in $modes.Keys) { if ($modes[$k] -eq $m) { return $k } }
    "custom: $m"
}

function LoadCfg($cfg) {
    $s = $null
    if (Test-Path $cfg) { $s = [IO.File]::ReadAllText($cfg) | ConvertFrom-Json }   # invalid JSON throws: never clobber it
    if (-not $s) { $s = [pscustomobject]@{} }
    $s
}

function SaveCfg($cfg, $s) { [IO.File]::WriteAllText($cfg, ($s | ConvertTo-Json -Depth 100)) }   # UTF-8 without BOM

function SetPerm($cfg, $mode) {
    $mode = Mode $mode
    $s = LoadCfg $cfg
    if (-not $s.permissions) { $s | Add-Member -Force -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) }
    $s.permissions | Add-Member -Force -NotePropertyName defaultMode -NotePropertyValue $modes[$mode]
    # without this claude stops at a "bypass mode is dangerous" dialog on first start
    if ($mode -eq 'bypass') { $s | Add-Member -Force -NotePropertyName skipDangerousModePermissionPrompt -NotePropertyValue $true }
    SaveCfg $cfg $s
}

function SetKey($cfg, $key) {   # API-key login = env.ANTHROPIC_API_KEY in the profile's settings.json, which claude loads itself
    $s = LoadCfg $cfg
    if (-not $s.env) { $s | Add-Member -Force -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
    $s.env | Add-Member -Force -NotePropertyName ANTHROPIC_API_KEY -NotePropertyValue $key
    SaveCfg $cfg $s
}

# Encrypted backup = 'CCPENC1' + salt(16) + iv(16) + AES-256-CBC(zip) + HMAC-SHA256 of all before it.
# Keys come from the password via PBKDF2; the HMAC is what detects a wrong password or tampering.
$magic = [Text.Encoding]::ASCII.GetBytes('CCPENC1')

function AskPassword([switch]$Twice) {   # $env:CCP_PASSWORD skips the prompt (scripts)
    if ($env:CCP_PASSWORD) { return $env:CCP_PASSWORD }
    $p = [Net.NetworkCredential]::new('', (Read-Host 'Password' -AsSecureString)).Password
    if (-not $p) { throw 'Empty password' }
    if ($Twice -and [Net.NetworkCredential]::new('', (Read-Host 'Repeat password' -AsSecureString)).Password -cne $p) {
        throw "Passwords don't match"
    }
    $p
}

function Keys($pw, [byte[]]$salt) {   # 64 bytes: AES key + HMAC key
    $kdf = [Security.Cryptography.Rfc2898DeriveBytes]::new([string]$pw, $salt, 200000, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { , $kdf.GetBytes(64) } finally { $kdf.Dispose() }
}

function IsEncrypted([byte[]]$b) {
    $b.Length -ge $magic.Length -and [Text.Encoding]::ASCII.GetString($b, 0, $magic.Length) -ceq 'CCPENC1'
}

function Encrypt([byte[]]$plain, $pw) {
    $salt = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    [byte[]]$k = Keys $pw $salt
    $aes = [Security.Cryptography.Aes]::Create()   # CBC + PKCS7, fresh random IV
    $aes.Key = [byte[]]$k[0..31]
    [byte[]]$body = $magic + $salt + $aes.IV + $aes.CreateEncryptor().TransformFinalBlock($plain, 0, $plain.Length)
    , [byte[]]($body + [Security.Cryptography.HMACSHA256]::new([byte[]]$k[32..63]).ComputeHash($body))
}

function Decrypt([byte[]]$b, $pw) {
    $h = $magic.Length
    if ($b.Length -lt $h + 80) { throw 'Backup file is truncated' }
    [byte[]]$k = Keys $pw ([byte[]]$b[$h..($h + 15)])
    $n = $b.Length - 32
    $mac = [Security.Cryptography.HMACSHA256]::new([byte[]]$k[32..63]).ComputeHash($b, 0, $n)
    $diff = 0
    for ($i = 0; $i -lt 32; $i++) { $diff = $diff -bor ($mac[$i] -bxor $b[$n + $i]) }   # constant-time compare
    if ($diff) { throw 'Wrong password (or the backup is corrupt)' }
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Key = [byte[]]$k[0..31]
    $aes.IV = [byte[]]$b[($h + 16)..($h + 31)]
    , $aes.CreateDecryptor().TransformFinalBlock($b, $h + 32, $n - $h - 32)
}

function SplitOnly($o) {   # pull `--only <name>` out of an arg list -> @{ Only; Rest }
    $i = [array]::IndexOf([object[]]$o, '--only')
    if ($i -lt 0) { return @{ Rest = $o } }
    if ($i + 1 -ge $o.Count) { throw '--only needs a profile name' }
    @{ Only = $o[$i + 1]; Rest = @(for ($j = 0; $j -lt $o.Count; $j++) { if ($j -ne $i -and $j -ne $i + 1) { $o[$j] } }) }
}

function WithHome($dir, [scriptblock]$body) {
    $old = [Environment]::GetEnvironmentVariable($var)
    [Environment]::SetEnvironmentVariable($var, $dir)
    try { & $body } finally { [Environment]::SetEnvironmentVariable($var, $old) }
}

# Subscription limits, from the endpoint behind claude's own /usage screen.
# ponytail: undocumented API; if it changes, this prints "unavailable" and only Usage needs fixing.
function Usage($n) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 'Tls12'
    $ProgressPreference = 'SilentlyContinue'
    $idx = [array]::IndexOf(@(Names), $n) + 1   # same number `ccp list` shows
    $d = ProfileDir $n
    $f = Join-Path (ProfilePath $n) '.credentials.json'
    $read = { if (Test-Path $f) { ([IO.File]::ReadAllText($f) | ConvertFrom-Json).claudeAiOauth } }
    # the shape `ccp usage --json` prints: keep it stable, scripts depend on it
    $r = [ordered]@{ index = $idx; profile = $n; note = (GetNote $n); status = 'ok'; error = $null; five_hour = $null; week = $null
        # the fields below are shared with `cxp usage --json`, so one script can rank both tools' profiles
        number = $idx; path = (ProfilePath $n); pool = (InPool $n); headroom_percent = $null; available = $false }
    $o = & $read
    if (-not $o.accessToken) {
        $r.status = 'no_login'
        # an API-key profile can still run work; it just has no subscription window to measure
        try { $r.available = [bool](LoadCfg (ConfigPath $n)).env.ANTHROPIC_API_KEY } catch { }
        return [pscustomobject]$r
    }
    if ($o.expiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) {
        # stale token: let claude refresh it. Via cmd so its stderr can't trip $ErrorActionPreference.
        WithHome $d { cmd /c 'claude auth status >nul 2>&1' }
        $o = & $read
    }
    try {
        $u = Invoke-RestMethod 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 20 -Headers @{
            Authorization = "Bearer $($o.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20'
        }
    } catch {
        $r.status = 'unavailable'; $r.error = $_.Exception.Message
        if ($_.Exception.Response.StatusCode.value__ -eq 401) { $r.status = 'expired' }
        return [pscustomobject]$r
    }
    $win = {   # null = no window open, nothing used
        param($w)
        if ($w) {
            # resets_at can be null (window reported but no reset time yet)
            $at = $null
            if ($w.resets_at) { $at = ([DateTimeOffset]$w.resets_at).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') }
            [ordered]@{ percent = [int]$w.utilization; resets_at = $at }
        }
    }
    $r.five_hour = & $win $u.five_hour
    $r.week = & $win $u.seven_day
    $used = 0   # the fullest open window decides how much room is left
    foreach ($w in $r.five_hour, $r.week) { if ($w -and $w.percent -gt $used) { $used = $w.percent } }
    $r.headroom_percent = [math]::Max(0, 100 - $used)
    $r.available = $r.headroom_percent -gt 0
    [pscustomobject]$r
}

function UsageText($r) {
    switch ($r.status) {
        'no_login'    { return 'no subscription login (API-key profile?)' }
        'expired'     { return "login expired; refresh it: ccp run $($r.profile)" }
        'unavailable' { return "unavailable ($($r.error))" }
    }
    $fmt = {
        param($w)
        if (-not $w) { return '-'.PadRight(23) }   # padded to line up with a filled window
        if (-not $w.resets_at) { return ('{0,3}% (no reset time)' -f $w.percent).PadRight(23) }
        '{0,3}% (resets {1:ddd HH:mm})' -f $w.percent, [DateTimeOffset]::Parse($w.resets_at).LocalDateTime
    }
    "5h $(& $fmt $r.five_hour)   week $(& $fmt $r.week)"
}

function Opts { , @(@($name) + $rest | Where-Object { $_ }) }   # everything after the command, for commands whose flags go anywhere

switch ($cmd) {
    'repair' {
        & (Join-Path $PSScriptRoot 'repair.ps1') -Tool ccp -Root $base -RepairArguments @($args | Select-Object -Skip 1)
    }
    'list' {
        $def = DefaultName
        $asJson = (Opts) -contains '--json'
        $i = 0
        $rows = @(foreach ($n in Names) {
            $i++
            $active = (ProfileDir $n) -eq $env:CLAUDE_CONFIG_DIR
            $note = GetNote $n
            if ($asJson) {   # same fields as `cxp list --json`; for home, run claude with CLAUDE_CONFIG_DIR unset
                [pscustomobject]@{ number = $i; name = $n; active = $active; default = ($n -eq $def)
                    path = ProfilePath $n; permissions = GetPerm (ConfigPath $n); note = $note; pool = InPool $n }
                continue
            }
            $mark = ' '
            if ($active) { $mark = '*' }
            $tag = ''
            if ($n -eq $def) { $tag = ' (default)' }
            $line = "$mark $i $n$tag [$(GetPerm (ConfigPath $n))]"
            if (-not (InPool $n)) { $line += ' [pool off]' }
            if ($note) { $line += "  # $note" }
            $line
        })
        if ($asJson) { ConvertTo-Json -Compress -Depth 3 -InputObject $rows } else { $rows }
    }
    'add' {
        $dir = NewProfileDir $name
        $key = $null
        if ($rest[0] -in '--key', '--api-key') {
            $key = $rest[1]
            if (-not $key) {   # prompt hidden, so the key stays out of shell history
                $key = [Net.NetworkCredential]::new('', (Read-Host 'API key' -AsSecureString)).Password
            }
            $key = "$key".Trim()
            if (-not $key) { throw 'No API key given, nothing created' }
        }
        New-Item -ItemType Directory $dir | Out-Null
        $cfg = Join-Path $dir 'settings.json'
        SetPerm $cfg 'auto'   # safe default; `ccp perm <name> bypass` opts out of all prompts
        HomeSkills $dir
        if ($key) { SetKey $cfg $key } else { WithHome $dir { claude auth login } }
        "Created '$name'. Switch to it: ccp use $name"
    }
    'use' {   # ccp use [name] [--local]
        $o = Opts
        $name = Resolve (@($o -ne '--local')[0])
        $dir = ProfileDir $name
        [Environment]::SetEnvironmentVariable($var, $dir)           # this terminal
        if ($o -contains '--local') { "Now using '$name' (this terminal only)" }
        else {
            [Environment]::SetEnvironmentVariable($var, $dir, 'User')   # new terminals / apps
            "Now using '$name'"
        }
    }
    'path' {   # the profile's config folder. --env: the value CLAUDE_CONFIG_DIR needs (nothing for home); ccp.sh uses it
        $o = Opts
        $name = Resolve (@($o | Where-Object { $_ -notin '--env', '--local' })[0])
        if ($o -contains '--env') { ProfileDir $name } else { ProfilePath $name }
    }
    'run' {   # ccp run <name> [--perm <mode>] [claude args]
        $name = Resolve $name
        if ($rest[0] -eq '--perm') {   # only as the first argument, so claude's own flags stay untouched
            $v = $modes[(Mode $rest[1])]
            if ($v -eq 'default') { $v = 'manual' }   # the CLI flag's name for settings.json's "default"
            $rest = @('--permission-mode', $v) + @($rest | Select-Object -Skip 2)
        }
        WithHome (ProfileDir $name) { claude @rest }
        exit $LASTEXITCODE   # scripts need claude's own exit code
    }
    'pool' {   # ccp pool <name> [on|off]
        $name = Resolve $name
        $f = PoolPath $name
        switch ("$($rest[0])") {
            ''    { }
            'on'  { if (Test-Path $f) { Remove-Item $f } }
            'off' { New-Item -ItemType Directory -Force $root | Out-Null; [IO.File]::WriteAllText($f, '') }
            default { throw "Use: ccp pool <name> [on|off]" }
        }
        if (InPool $name) { "'$name' is in the pool" } else { "'$name' is out of the pool (ccp pick skips it)" }
    }
    'pick' {   # ccp pick [-n <count>] [--json]: pool profiles with room left, most headroom first
        $o = Opts
        $count = 1
        $i = [array]::IndexOf([object[]]$o, '-n')
        if ($i -ge 0) {
            if ("$($o[$i + 1])" -notmatch '^[1-9]\d*$') { throw '-n needs a number, e.g. ccp pick -n 3' }
            $count = [int]$o[$i + 1]
        }
        # out-of-pool profiles are skipped before any lookup, so their tokens are never sent
        $rows = @(foreach ($n in @(Names | Where-Object { InPool $_ })) { Usage $n }) | Where-Object { $_.available }
        $rows = @($rows | Sort-Object @{ Expression = { if ($null -eq $_.headroom_percent) { -1 } else { $_.headroom_percent } }; Descending = $true },
            @{ Expression = { $_.number } } | Select-Object -First $count)   # API-key profiles (no known headroom) go last
        if (-not $rows.Count) { throw 'No profile available: all are out of the pool, at their limit, or not logged in (see: ccp usage)' }
        if ($o -contains '--json') { ConvertTo-Json -Compress -Depth 5 -InputObject $rows } else { $rows.profile }
    }
    'default' {
        if ($name) {
            $name = Resolve $name
            ProfileDir $name | Out-Null   # must exist
            New-Item -ItemType Directory -Force $root | Out-Null
            Set-Content $defFile $name
            "Default is now '$name'"
        } else { "Default is '$(DefaultName)'" }
    }
    'rename' {
        $name = Resolve $name
        $old = ProfileDir $name
        if (-not $old) { throw "'home' is ~/.claude and can't be renamed" }
        $new = NewProfileDir $rest[0]
        Rename-Item $old $new
        if ((DefaultName) -eq $name) { Set-Content $defFile $rest[0] }
        Retarget $old $new
        "Renamed '$name' to '$($rest[0])'"
    }
    'remove' {
        $name = Resolve $name
        $dir = ProfileDir $name
        if (-not $dir) { throw "'home' is ~/.claude and can't be removed" }
        if ($rest -notcontains '-y') {
            $ans = Read-Host "Delete '$name' and ALL its data (login, sessions, history)? Type the name to confirm"
            if ($ans -ne $name) { throw 'Cancelled, nothing deleted' }
        }
        Remove-Item -Recurse -Force $dir
        if ((DefaultName) -eq $name) { Remove-Item $defFile }   # default falls back to home
        Retarget $dir $null                                      # if it was active, back to home
        "Removed '$name'"
    }
    'perm' {
        $name = Resolve $name
        $cfg = ConfigPath $name
        if ($rest.Count) { SetPerm $cfg $rest[0] }
        "'$name' permissions: $(GetPerm $cfg)"
    }
    'note' {   # ccp note <name> [text...] | --clear
        $name = Resolve $name
        $f = NotePath $name
        if ($rest -contains '--clear') {
            if (Test-Path $f) { Remove-Item $f }
            "Cleared note for '$name'"
        } elseif ($rest.Count) {
            $text = (($rest -join ' ') -replace '\s+', ' ').Trim()
            [IO.File]::WriteAllText($f, $text)
            "Note for '$name': $text"
        } else {
            $note = GetNote $name
            if ($note) { $note } else { "No note for '$name'. Set one: ccp note $name <text>" }
        }
    }
    'usage' {
        $opts = Opts
        $who = @($opts -ne '--json')[0]
        $list = @(Names)
        if ($who) { $list = @(Resolve $who) }
        if ($opts -contains '--json') {   # always an array, one line, even for a single profile
            ConvertTo-Json -Compress -Depth 5 -InputObject @(foreach ($n in $list) { Usage $n })
        } else {
            $w = ($list | Measure-Object Length -Maximum).Maximum
            foreach ($n in $list) {
                $r = Usage $n
                $line = "$($r.index) $($n.PadRight($w))  $(UsageText $r)"
                if (-not $r.pool) { $line += '  [pool off]' }
                if ($r.note) { $line += "  # $($r.note)" }
                $line
            }
        }
    }
    'backup' {   # ccp backup [file] [-p | --password] [--only <name>] [--creds], in any order
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $o = SplitOnly @(@($name) + $rest | Where-Object { $_ })
        $opts = @($o.Rest)
        $names = @(Names | Select-Object -Skip 1)
        if ($o.Only) {
            $n = Resolve $o.Only
            if (-not (ProfileDir $n)) { throw "'home' is ~/.claude and isn't part of backups" }
            $names = @($n)
        }
        $enc = [bool]@($opts | Where-Object { $_ -in '-p', '--password' }).Count
        $creds = $opts -contains '--creds'   # the login alone: no settings, notes or data
        $files = $acctFiles
        if ($creds) { $files = $credFiles }
        $file = @($opts | Where-Object { $_ -notin '-p', '--password', '--creds' })[0]
        if (-not $file) {
            $dir = Join-Path $base 'backups'
            New-Item -ItemType Directory -Force $dir | Out-Null
            $file = Join-Path $dir "ccp-$(Get-Date -Format yyyyMMdd-HHmmss)"
            if ($creds) { $file += '-creds' }
            $file += '.zip'
            if ($enc) { $file += '.enc' }
        }
        $file = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($file)   # .NET's cwd isn't PowerShell's
        if (Test-Path $file) { throw "'$file' already exists" }
        $found = @(foreach ($n in $names) {
            foreach ($f in $files) {
                $p = Join-Path (Join-Path $root $n) $f
                if (Test-Path $p) { [pscustomobject]@{ Path = $p; Entry = "$n/$f"; Profile = $n } }
            }
        })
        if (-not $found.Count) { throw 'No profiles to back up' }
        $pw = $null
        if ($enc) { $pw = AskPassword -Twice }
        $ms = [IO.MemoryStream]::new()   # account files are small: build in memory so nothing unencrypted hits disk
        $zip = [IO.Compression.ZipArchive]::new($ms, 'Create', $true)
        try { foreach ($x in $found) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $x.Path, $x.Entry) } }
        finally { $zip.Dispose() }
        [byte[]]$bytes = $ms.ToArray()
        if ($enc) { [byte[]]$bytes = Encrypt $bytes $pw }
        [IO.File]::WriteAllBytes($file, $bytes)
        $what = ''
        if ($creds) { $what = ' (logins only)' }
        "Backed up $(@($found.Profile | Select-Object -Unique).Count) profile(s)$what to $file"
        if ($enc) { 'Encrypted: without the password it cannot be restored.' }
        else { 'It contains login tokens: keep it private (or encrypt it: ccp backup -p).' }
    }
    'restore' {   # $name is the backup file; encrypted ones are detected and ask for the password. --creds: logins only
        $o = SplitOnly @(@($name) + $rest | Where-Object { $_ })
        $yes = $o.Rest -contains '-y'
        $creds = $o.Rest -contains '--creds'
        $file = @($o.Rest | Where-Object { $_ -notin '-y', '-p', '--password', '--creds' })[0]   # encryption is detected; the flag is accepted for cxp parity
        if (-not $file) { throw 'Missing backup file' }
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        [byte[]]$bytes = [IO.File]::ReadAllBytes((Resolve-Path $file).ProviderPath)
        if (IsEncrypted $bytes) { [byte[]]$bytes = Decrypt $bytes (AskPassword) }
        $zip = [IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($bytes), 'Read')
        try {
            # only <profile>/<account file> entries: nothing in the zip can land outside profiles\
            foreach ($e in $zip.Entries) {
                if ($e.FullName -notmatch '^([^/\\]+)/([^/\\]+)$' -or $Matches[2] -notin $acctFiles -or
                    $Matches[1] -notmatch $nameRe -or $Matches[1] -match '^(\d+|home|default)$') {
                    throw "Not a ccp backup: unexpected entry '$($e.FullName)'"
                }
            }
            $groups = @($zip.Entries | Group-Object { $_.FullName.Split('/')[0] })
            if ($o.Only) {   # matched by the name inside the backup, not a local list number
                $in = $groups.Name -join ', '
                $groups = @($groups | Where-Object Name -eq $o.Only)
                if (-not $groups.Count) { throw "No profile '$($o.Only)' in this backup (it has: $in)" }
            }
            foreach ($g in $groups) {
                $dir = Join-Path $root $g.Name
                $want = @($g.Group)
                if ($creds) { $want = @($want | Where-Object { $_.Name -in $credFiles }) }
                if (-not $want.Count) { "Skipped '$($g.Name)': no login in this backup"; continue }
                if ((Test-Path $dir) -and -not $yes) {
                    if ($creds) { "Skipped '$($g.Name)': already exists (-y overwrites its login)" }
                    else { "Skipped '$($g.Name)': already exists (-y overwrites its login and settings)" }
                    continue
                }
                New-Item -ItemType Directory -Force $dir | Out-Null
                foreach ($e in $want) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dir $e.Name), $true) }
                if ($creds) { "Restored login for '$($g.Name)'" } else { "Restored '$($g.Name)'" }
            }
        } finally { $zip.Dispose() }
    }
    'install' {   # make `ccp` a command everywhere; safe to re-run
        $dir = $PSScriptRoot
        # PowerShell (5.1 and 7) runs ccp.ps1 by name once its folder is on PATH. Go through the
        # registry, not SetEnvironmentVariable, so %VAR% entries and the value kind survive.
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        try {
            $path = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
            if (($path -split ';') -contains $dir) { 'PowerShell: already on PATH' }
            else {
                $kind = 'ExpandString'
                if ($path) { $kind = $key.GetValueKind('Path') }
                $key.SetValue('Path', (@($path.TrimEnd(';'), $dir) -ne '' -join ';'), $kind)
                [Environment]::SetEnvironmentVariable('CCP_INSTALL', $null, 'User')   # no-op that broadcasts the change to Explorer
                "PowerShell: added $dir to your PATH"
            }
        } finally { $key.Close() }
        if (($env:PATH -split ';') -notcontains $dir) { $env:PATH = "$env:PATH;$dir" }   # this terminal
        # Git Bash needs the ccp.sh function (a child process can't switch the shell's profile)
        $rc = Join-Path $HOME '.bashrc'
        if ((Test-Path $rc) -or (Get-Command git -ErrorAction SilentlyContinue)) {
            $line = "source `"$($dir -replace '\\', '/')/ccp.sh`""
            $text = ''
            if (Test-Path $rc) { $text = [IO.File]::ReadAllText($rc) }
            if ($text.Contains('/ccp.sh')) { 'Git Bash: already in ~/.bashrc' }
            else {
                if ($text -and -not $text.EndsWith("`n")) { $line = "`n$line" }
                [IO.File]::AppendAllText($rc, "$line`n")   # UTF-8 without BOM, LF
                'Git Bash: added to ~/.bashrc (open a new Git Bash, or: source ~/.bashrc)'
            }
        }
        'Done. `ccp` works here now and in every new terminal.'
    }
    default {
        @'
ccp install            make `ccp` a command in PowerShell and Git Bash (run once)
ccp repair [--from <old-folder>] [--apply]
                       preview relocation repairs; --apply writes with backups (Python 3.11+)
ccp list [--json]      show profiles (* = active in this terminal)
ccp add <name>         create a profile and log in to it
ccp add <name> --key   same, but with an Anthropic API key instead of a login
                       (prompts for it; or pass it: --key sk-ant-...; --api-key works too)
ccp use [name] [--local]
                       switch (this terminal + all new ones); no name = default;
                       --local switches this terminal only
ccp run <name> [--perm <mode>] [args]
                       run claude once under a profile without switching;
                       --perm overrides the permission mode for this run only
ccp path <name>        print the profile's config folder
ccp default [name]     show / pick the default profile
ccp perm <name> [mode] show / set permissions: bypass (no prompts), auto, edits
                       (auto-accept file edits), ask, plan (read-only; also
                       accepted as readonly). New profiles get auto.
ccp usage [name]       how much of the 5-hour and weekly subscription limits each
                       profile has used, and when they reset (no name = all);
                       add --json for scripts
ccp pool <name> [on|off]
                       show / set whether `ccp pick` may choose this profile
ccp pick [-n <count>] [--json]
                       print the pool profile(s) with the most room left
ccp note <name> [text] show / set a one-line note on a profile (--clear removes it);
                       notes appear in `ccp list` and `ccp usage`
ccp rename <old> <new> rename a profile
ccp remove <name> [-y] delete a profile and all its data (-y skips the prompt)
ccp backup [file] [-p] save every profile's login + settings to a zip (default: .\backups\);
                       -p (or --password) encrypts it with a password you type
ccp restore <file> [-y] bring profiles back from a backup (-y overwrites existing ones);
                       asks for the password if the backup is encrypted
                       Both take --only <name> to save / bring back a single profile,
                       and --creds to save / bring back only the logins (no settings,
                       notes or data).
"home" is your original ~/.claude. Anywhere a name goes you can also give
"default" or the number from `ccp list` (ccp use 2).
'@
    }
}
