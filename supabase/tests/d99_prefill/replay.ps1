param([switch]$KeepDatabase)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$replayRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('nubo-d99-replay-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$projectId=Split-Path $replayRoot -Leaf
New-Item -ItemType Directory -Path (Join-Path $replayRoot 'supabase/migrations') -Force | Out-Null
$config=[System.IO.File]::ReadAllText((Join-Path $repoRoot 'supabase/config.toml'))
$config=$config.Replace('project_id = "nubo-conecta-admin"','project_id = "'+$projectId+'"').Replace('port = 54322','port = 55492').Replace('shadow_port = 54320','shadow_port = 55493')
[System.IO.File]::WriteAllText((Join-Path $replayRoot 'supabase/config.toml'),$config)
Copy-Item -LiteralPath (Join-Path $repoRoot 'supabase/roles.sql') -Destination (Join-Path $replayRoot 'supabase/roles.sql')
Copy-Item -LiteralPath (Join-Path $repoRoot 'supabase/production_baseline.sql') -Destination (Join-Path $replayRoot 'supabase/migrations/20260814160000_production_baseline.sql')
Get-ChildItem -LiteralPath (Join-Path $repoRoot 'supabase/migrations') -Filter '*.sql' | Where-Object { $_.Name.Substring(0,14) -gt '20260814160000' } | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $replayRoot 'supabase/migrations') }
Write-Output "D99 local replay: project=$projectId root=$replayRoot port=55492"
try {
 & npx --yes supabase@2.98.2 --workdir $replayRoot db start
 if($LASTEXITCODE -ne 0){throw 'Full migration replay failed'}
 & docker exec ('supabase_db_'+$projectId) psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT count(*) AS migrations FROM supabase_migrations.schema_migrations; SELECT to_regprocedure('public.commit_prefill_v1(jsonb)') AS commit_rpc;"
 if($LASTEXITCODE -ne 0){throw 'Replay verification failed'}
 Write-Output 'D99_FULL_REPLAY_PASS'
} finally {
 if(-not $KeepDatabase) {
  & npx --yes supabase@2.98.2 --workdir $replayRoot stop --no-backup
 }
}
