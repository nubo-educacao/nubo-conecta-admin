param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$replayRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('nubo-a98-replay-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$projectId=Split-Path $replayRoot -Leaf
$container='supabase_db_'+$projectId
$cli=(Get-Command supabase -ErrorAction SilentlyContinue).Source
$cliPrefix=@()
if(-not $cli){$cli=(Get-Command npx -ErrorAction Stop).Source; $cliPrefix=@('--yes','supabase@2.98.2')}
New-Item -ItemType Directory -Path (Join-Path $replayRoot 'supabase/migrations') -Force | Out-Null
$config=[System.IO.File]::ReadAllText((Join-Path $repoRoot 'supabase/config.toml'))
$config=$config.Replace('project_id = "nubo-conecta-admin"','project_id = "'+$projectId+'"').Replace('port = 54322','port = 55494').Replace('shadow_port = 54320','shadow_port = 55495')
[System.IO.File]::WriteAllText((Join-Path $replayRoot 'supabase/config.toml'),$config)
Copy-Item -LiteralPath (Join-Path $repoRoot 'supabase/roles.sql') -Destination (Join-Path $replayRoot 'supabase/roles.sql')
Copy-Item -LiteralPath (Join-Path $repoRoot 'supabase/production_baseline.sql') -Destination (Join-Path $replayRoot 'supabase/migrations/20260814160000_production_baseline.sql')
Get-ChildItem -LiteralPath (Join-Path $repoRoot 'supabase/migrations') -Filter '*.sql' | Where-Object { $_.Name.Substring(0,14) -gt '20260814160000' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $replayRoot 'supabase/migrations') }
Write-Output "A98 local-only replay: project=$projectId container=$container port=55494"
try {
 & $cli @cliPrefix --version
 & $cli @cliPrefix --workdir $replayRoot db start
 if($LASTEXITCODE -ne 0){throw 'A98 full migration replay failed'}
 & docker exec $container psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT count(*) AS migrations FROM supabase_migrations.schema_migrations; SELECT to_regprocedure('cursinho_prefill.validate_origin_v1(uuid,text,jsonb)') AS validator;"
 if($LASTEXITCODE -ne 0){throw 'A98 replay verification failed'}
 & node (Join-Path $PSScriptRoot 'concurrency.mjs') $container
 if($LASTEXITCODE -ne 0){throw 'A98 concurrent SQL assertions failed'}
 Write-Output 'A98_FULL_REPLAY_AND_CONCURRENCY_PASS'
} finally {
 # Stop only the random project created above. Never stop/reset the user's stack.
 & $cli @cliPrefix --workdir $replayRoot stop --no-backup
 if($LASTEXITCODE -ne 0){throw "Could not stop exclusive replay project $projectId"}
}
