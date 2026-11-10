# ccp - Claude Code profile switcher. Each profile is its own CLAUDE_CONFIG_DIR
# (separate login, sessions, history, settings) under .\profiles\<name>.
# "home" is the stock ~/.claude. "default" (or no name) is an alias for
# whichever profile `ccp default <name>` picked; home until you pick one.
$ErrorActionPreference = 'Stop'
trap { [Console]::Error.WriteLine("ccp: $_"); exit 1 }   # one-line errors, no stack trace
$cmd = $args[0]; $name = $args[1]   # no param(): claude flags like -p must pass through untouched
$rest = @($args | Select-Object -Skip 2)
$root = Join-Path $PSScriptRoot 'profiles'
$defFile = Join-Path $root '.default'
$var = 'CLAUDE_CONFIG_DIR'
# Names become folder names: . @ + only singly between word chars, so emails
# work but "..", leading dots (.default) and trailing dots (Windows strips them) don't.
$nameRe = '^[\w-]+([.@+][\w-]+)*$'
# What `backup` saves per profile: the account (login + identity) and settings, not sessions/history.
$acctFiles = '.credentials.json', '.claude.json', 'settings.json'

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

function ConfigPath($n) {
    $d = ProfileDir $n
    if (-not $d) { $d = Join-Path $HOME '.claude' }
    Join-Path $d 'settings.json'
}

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
    if (-not $modes.Contains($mode)) { throw "Unknown mode '$mode'. Use: $($modes.Keys -join ', ')" }
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
    $d = ProfileDir $n
    $f = Join-Path $(if ($d) { $d } else { Join-Path $HOME '.claude' }) '.credentials.json'
    $read = { if (Test-Path $f) { ([IO.File]::ReadAllText($f) | ConvertFrom-Json).claudeAiOauth } }
    # the shape `ccp usage --json` prints: keep it stable, scripts depend on it
    $r = [ordered]@{ profile = $n; status = 'ok'; error = $null; five_hour = $null; week = $null }
    $o = & $read
    if (-not $o.accessToken) { $r.status = 'no_login'; return [pscustomobject]$r }
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
        if ($w) { [ordered]@{ percent = [int]$w.utilization; resets_at = ([DateTimeOffset]$w.resets_at).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } }
    }
    $r.five_hour = & $win $u.five_hour
    $r.week = & $win $u.seven_day
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
        '{0,3}% (resets {1:ddd HH:mm})' -f $w.percent, [DateTimeOffset]::Parse($w.resets_at).LocalDateTime
    }
    "5h $(& $fmt $r.five_hour)   week $(& $fmt $r.week)"
}

switch ($cmd) {
    'list' {
        $def = DefaultName
        $i = 0
        foreach ($n in Names) {
            $i++
            $mark = ' '
            if ((ProfileDir $n) -eq $env:CLAUDE_CONFIG_DIR) { $mark = '*' }
            $tag = ''
            if ($n -eq $def) { $tag = ' (default)' }
            "$mark $i $n$tag [$(GetPerm (ConfigPath $n))]"
        }
    }
    'add' {
        $dir = NewProfileDir $name
        $key = $null
        if ($rest[0] -eq '--key') {
            $key = $rest[1]
            if (-not $key) {   # prompt hidden, so the key stays out of shell history
                $key = [Net.NetworkCredential]::new('', (Read-Host 'API key' -AsSecureString)).Password
            }
            $key = "$key".Trim()
            if (-not $key) { throw 'No API key given, nothing created' }
        }
        New-Item -ItemType Directory $dir | Out-Null
        $cfg = Join-Path $dir 'settings.json'
        SetPerm $cfg 'bypass'   # new profiles default to bypass all
        if ($key) { SetKey $cfg $key } else { WithHome $dir { claude auth login } }
        "Created '$name'. Switch to it: ccp use $name"
    }
    'use' {
        $name = Resolve $name
        $dir = ProfileDir $name
        [Environment]::SetEnvironmentVariable($var, $dir)           # this terminal
        [Environment]::SetEnvironmentVariable($var, $dir, 'User')   # new terminals / apps
        "Now using '$name'"
    }
    'run' {
        $name = Resolve $name
        WithHome (ProfileDir $name) { claude @rest }
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
    'usage' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 'Tls12'
        $ProgressPreference = 'SilentlyContinue'
        $opts = @(@($name) + $rest | Where-Object { $_ })
        $who = @($opts -ne '--json')[0]
        $list = @(Names)
        if ($who) { $list = @(Resolve $who) }
        if ($opts -contains '--json') {   # always an array, one line, even for a single profile
            ConvertTo-Json -Compress -Depth 5 -InputObject @(foreach ($n in $list) { Usage $n })
        } else {
            $w = ($list | Measure-Object Length -Maximum).Maximum
            foreach ($n in $list) { "$($n.PadRight($w))  $(UsageText (Usage $n))" }
        }
    }
    'backup' {   # ccp backup [file] [-p] [--only <name>], in any order
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $o = SplitOnly @(@($name) + $rest | Where-Object { $_ })
        $opts = @($o.Rest)
        $names = @(Names | Select-Object -Skip 1)
        if ($o.Only) {
            $n = Resolve $o.Only
            if (-not (ProfileDir $n)) { throw "'home' is ~/.claude and isn't part of backups" }
            $names = @($n)
        }
        $enc = $opts -contains '-p'
        $file = @($opts -ne '-p')[0]
        if (-not $file) {
            $dir = Join-Path $PSScriptRoot 'backups'
            New-Item -ItemType Directory -Force $dir | Out-Null
            $file = Join-Path $dir "ccp-$(Get-Date -Format yyyyMMdd-HHmmss).zip"
            if ($enc) { $file += '.enc' }
        }
        $file = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($file)   # .NET's cwd isn't PowerShell's
        if (Test-Path $file) { throw "'$file' already exists" }
        $found = @(foreach ($n in $names) {
            foreach ($f in $acctFiles) {
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
        "Backed up $(@($found.Profile | Select-Object -Unique).Count) profile(s) to $file"
        if ($enc) { 'Encrypted: without the password it cannot be restored.' }
        else { 'It contains login tokens: keep it private (or encrypt it: ccp backup -p).' }
    }
    'restore' {   # $name is the backup file; encrypted ones are detected and ask for the password
        $o = SplitOnly @(@($name) + $rest | Where-Object { $_ })
        $yes = $o.Rest -contains '-y'
        $file = @($o.Rest -ne '-y')[0]
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
                if ((Test-Path $dir) -and -not $yes) {
                    "Skipped '$($g.Name)': already exists (-y overwrites its login and settings)"
                    continue
                }
                New-Item -ItemType Directory -Force $dir | Out-Null
                foreach ($e in $g.Group) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dir $e.Name), $true) }
                "Restored '$($g.Name)'"
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
ccp list               show profiles (* = active in this terminal)
ccp add <name>         create a profile and log in to it
ccp add <name> --key   same, but with an Anthropic API key instead of a login
                       (prompts for it; or pass it: --key sk-ant-...)
ccp use [name]         switch (this terminal + all new ones); no name = default
ccp run <name> [args]  run claude once under a profile without switching
ccp default [name]     show / pick the default profile
ccp perm <name> [mode] show / set permissions: bypass (no prompts), auto, edits
                       (auto-accept file edits), ask, plan. New profiles get bypass.
ccp usage [name]       how much of the 5-hour and weekly subscription limits each
                       profile has used, and when they reset (no name = all);
                       add --json for scripts
ccp rename <old> <new> rename a profile
ccp remove <name> [-y] delete a profile and all its data (-y skips the prompt)
ccp backup [file] [-p] save every profile's login + settings to a zip (default: .\backups\);
                       -p encrypts it with a password you type
ccp restore <file> [-y] bring profiles back from a backup (-y overwrites existing ones);
                       asks for the password if the backup is encrypted
                       Both take --only <name> to save / bring back a single profile.
"home" is your original ~/.claude. Anywhere a name goes you can also give
"default" or the number from `ccp list` (ccp use 2).
'@
    }
}
