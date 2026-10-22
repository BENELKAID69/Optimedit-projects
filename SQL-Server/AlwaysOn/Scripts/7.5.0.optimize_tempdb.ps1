<#
.SYNOPSIS
    Optimise TempDB (4 fichiers de 2 Go) sur SQLS01 et SQLS02.

.DESCRIPTION
    Chapitre 7.5 - Optimisation TempDB.
    Configure TempDB avec 4 fichiers de donnees (tempdev, tempdev2-4) pre-dimensionnes
    a 2 Go, avec FILEGROWTH = 512 Mo et MAXSIZE = 8 Go. Le log est porte a 512 Mo.

    Pre-requis :
      - Dossier S:\SQL\TempDB\ existant sur les deux noeuds
      - Espace disque suffisant sur S:\ (au moins 10 Go libres)
      - Les deux noeuds en bonne sante

    Note : TempDB n'est PAS repliquee par l'AG - il faut l'optimiser sur les 2 noeuds.

.PARAMETER SqlScriptPath
    Chemin du .sql. Defaut : .\Scripts-T-SQL\7.5.0.optimize_tempdb.sql

.PARAMETER TargetNodes
    Noeuds cibles. Defaut : SQLS01 + SQLS02.

.EXAMPLE
    .\7.5.0.optimize_tempdb.ps1 -WhatIf
    .\7.5.0.optimize_tempdb.ps1
	
	======================
   🚀 Séquence d'exécution
	======================

Set-Location "C:\Scripts\_Projet AlwaysOn"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# 1. Créer les fichiers (déjà fait : .sql + .ps1)
# 2. Prévisualiser
.\7.5.0.optimize_tempdb.ps1 -WhatIf

# 3. Exécuter
.\7.5.0.optimize_tempdb.ps1

# 4. Redémarrer SQLS02 EN PREMIER (pour minimiser l'impact)
Invoke-Command -ComputerName SQLS02.optimedit.eu -ScriptBlock {
    Restart-Service MSSQLSERVER -Force
    Start-Sleep -Seconds 15
    Get-Service MSSQLSERVER, SQLSERVERAGENT
}

⚠️ Le Restart-Service MSSQLSERVER -Force peut déclencher un auto-failover parce que :
-Force envoie un Stop-Service brutal

Le cluster peut interpréter cela comme une perte de nœud

Résultat : SQLS02 devient PRIMARY automatiquement

Pour éviter l'auto-failover lors des redémarrages, utilisez plutôt :

# Suspendre le cluster pour éviter l'auto-failover pendant la maintenance
Suspend-ClusterNode -Name "SQLS01" -Drain

# Redémarrer SQL Server
Invoke-Command -ComputerName SQLS01.optimedit.eu -ScriptBlock {
    Restart-Service MSSQLSERVER -Force
    Start-Sleep -Seconds 20
}

# Reprendre le nœud dans le cluster
Resume-ClusterNode -Name "SQLS01"

Ou Faire ce redemarrage avec -force et accepter que SQLS02 devienne PRIMARY temporairement et rebasculer après


***
Reprendre le nœud
# Reprendre SQLS01 (l'enlever de l'état suspendu)
Resume-ClusterNode -Name "SQLS01"

# Vérifier
Get-ClusterNode | Select-Object Name, State
***

# 5. Redémarrer SQLS01
Invoke-Command -ComputerName SQLS01.optimedit.eu -ScriptBlock {
    Restart-Service MSSQLSERVER -Force
    Start-Sleep -Seconds 15
    Get-Service MSSQLSERVER, SQLSERVERAGENT
}

# 6. Vérifier que les 4 fichiers existent
foreach ($node in @("SQLS01.optimedit.eu", "SQLS02.optimedit.eu")) {
    Write-Host "=== $node ===" -ForegroundColor Cyan
    Invoke-Sqlcmd -ServerInstance $node -Query @"
SELECT name, size * 8 / 1024 AS SizeMB FROM tempdb.sys.database_files WHERE type_desc = 'ROWS';
"@ -TrustServerCertificate | Format-Table -AutoSize
}

# 7. Vérifier la sante de l'AG
Invoke-Sqlcmd -ServerInstance "SQLS01.optimedit.eu" -TrustServerCertificate -Query @"
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;
"@


# Si SQLS01 bascule vers SECONDARY faire cette verification  ----------------------------------- 
# Interroger depuis SQLS02 (qui devrait être le nouveau PRIMARY)
Invoke-Sqlcmd -ServerInstance "SQLS02.optimedit.eu" -TrustServerCertificate -Query @"
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc, ars.synchronization_health_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;
"@

# Et l'état du cluster
Import-Module FailoverClusters
Get-ClusterGroup -Name "AG-OPTIMEDIT" | Select-Object Name, State, OwnerNode

# ***** REBASCULER SQLS01 VERS PRIMARY ***********************

Import-Module SqlServer
Switch-SqlAvailabilityGroup -Path "SQLSERVER:\SQL\SQLS01\DEFAULT\AvailabilityGroups\AG-OPTIMEDIT"

Start-Sleep -Seconds 15

# Vérifier
Invoke-Sqlcmd -ServerInstance "SQLS01.optimedit.eu" -TrustServerCertificate -Query @"
SELECT ar.replica_server_name, ars.role_desc, ars.connected_state_desc
FROM sys.dm_hadr_availability_replica_states ars
JOIN sys.availability_replicas ar ON ars.replica_id = ar.replica_id;
"@	
	
	
	
	
	
	
	
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$SqlScriptPath = ".\Scripts-T-SQL\7.5.0.optimize_tempdb.sql",
    [string[]]$TargetNodes = @("SQLS01.optimedit.eu", "SQLS02.optimedit.eu"),
    [string]$TranscriptPath = ".\7.5.0.optimize_tempdb.log"
)

$ErrorActionPreference = "Stop"

try {
    Start-Transcript -Path $TranscriptPath -Append -Force | Out-Null
} catch {
    Write-Warning "Impossible de demarrer la transcription : $($_.Exception.Message)"
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" }
        "INFO" { "Cyan" } "SKIP" { "DarkGray" } default { "White" }
    }
    $prefix = switch ($Status) {
        "OK" { "[OK]   " } "WARN" { "[WARN] " } "ERROR" { "[ERR]  " }
        "INFO" { "[INFO] " } "SKIP" { "[SKIP] " } default { "[----] " }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

try {
    Write-Section "7.5.0 - Optimisation TempDB"
    Write-Host " Nodes    : $($TargetNodes -join ', ')" -ForegroundColor Gray
    Write-Host " SQL      : $SqlScriptPath" -ForegroundColor Gray
    Write-Host " Date     : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " Mode     : $(if ($WhatIfPreference) { 'WhatIf' } else { 'Execution reelle' })" -ForegroundColor Gray

    # --- PRE-VOL 1 : Module SqlServer ---
    Write-Section "Pre-vol 1/4 : Module SqlServer"
    if (-not (Get-Module -Name SqlServer -ListAvailable -ErrorAction SilentlyContinue)) {
        throw "Module SqlServer introuvable."
    }
    if (-not (Get-Module -Name SqlServer -ErrorAction SilentlyContinue)) {
        Import-Module SqlServer -ErrorAction Stop
    }
    $m = Get-Module -Name SqlServer | Select-Object -First 1
    Write-Step "Module SqlServer v$($m.Version)" "OK"

    # --- PRE-VOL 2 : Fichier SQL present ---
    Write-Section "Pre-vol 2/4 : Fichier SQL source"
    if (-not (Test-Path -Path $SqlScriptPath -PathType Leaf)) {
        throw "Fichier introuvable : $SqlScriptPath"
    }
    $fileInfo = Get-Item $SqlScriptPath
    Write-Step "Trouve : $($fileInfo.Name) ($($fileInfo.Length) octets)" "OK"

    # --- PRE-VOL 3 : Dossier S:\SQL\TempDB et espace disque sur chaque noeud ---
    Write-Section "Pre-vol 3/4 : Dossier S:\SQL\TempDB + espace disque"
    foreach ($node in $TargetNodes) {
        $shortName = ($node -split '\.')[0]
        $check = Invoke-Command -ComputerName $node -ScriptBlock {
            $result = @{
                TempDbPath    = Test-Path "S:\SQL\TempDB"
                FreeSpaceGB   = 0
                TotalSpaceGB  = 0
            }
            try {
                $disk = Get-PSDrive -Name S -ErrorAction Stop
                $result.FreeSpaceGB  = [math]::Round($disk.Free / 1GB, 2)
                $result.TotalSpaceGB = [math]::Round(($disk.Used + $disk.Free) / 1GB, 2)
            } catch {
                # Ignorer
            }
            return $result
        } -ErrorAction Stop

        if (-not $check.TempDbPath) {
            throw "Dossier S:\SQL\TempDB introuvable sur $node."
        }
        Write-Step "$shortName : dossier S:\SQL\TempDB present" "OK"

        # Verification espace disque : minimum 10 GB libres (4 fichiers x 2 GB + marge)
        if ($check.FreeSpaceGB -lt 10) {
            throw "$shortName : espace disque insuffisant sur S:\ ($($check.FreeSpaceGB) GB libres, 10 GB requis)."
        }
        Write-Step "$shortName : espace disque S:\ - $($check.FreeSpaceGB) GB libres / $($check.TotalSpaceGB) GB total" "OK"
    }

    # --- PRE-VOL 4 : Etat actuel de TempDB ---
    Write-Section "Pre-vol 4/4 : Etat actuel de TempDB"
    foreach ($node in $TargetNodes) {
        $shortName = ($node -split '\.')[0]
        Write-Host ""
        Write-Host "  TempDB sur $shortName :" -ForegroundColor Cyan
        $q = @"
SELECT 
    name              AS LogicalName,
    size * 8 / 1024   AS SizeMB,
    growth * 8 / 1024 AS GrowthMB,
    is_percent_growth AS PercentGrowth,
    type_desc
FROM tempdb.sys.database_files
ORDER BY file_id;
"@
        Invoke-Sqlcmd -ServerInstance $node -Query $q -TrustServerCertificate | Format-Table -AutoSize
    }

    # --- EXECUTION ---
    foreach ($node in $TargetNodes) {
        Write-Section "Traitement de $node"

        if ($WhatIfPreference) {
            Write-Step "[WhatIf] Execution de $SqlScriptPath sur $node" "SKIP"
            continue
        }

        if ($PSCmdlet.ShouldProcess($node, "Optimiser TempDB")) {
            try {
                Invoke-Sqlcmd -ServerInstance $node -Database master `
                              -InputFile $SqlScriptPath `
                              -TrustServerCertificate `
                              -Verbose -ErrorAction Stop | Out-Null
                Write-Step "TempDB optimise sur $node" "OK"
            } catch {
                Write-Step "Erreur sur $node : $($_.Exception.Message)" "ERROR"
                throw
            }
        }
    }

    # --- VERIFICATION POST-EXECUTION ---
    if (-not $WhatIfPreference) {
        Write-Section "Verification post-execution"
        foreach ($node in $TargetNodes) {
            Write-Host ""
            Write-Host "  TempDB sur $node :" -ForegroundColor Cyan
            $q = @"
SELECT 
    name               AS LogicalName,
    physical_name      AS PhysicalPath,
    size * 8 / 1024    AS SizeMB,
    growth * 8 / 1024  AS GrowthMB,
    max_size * 8 / 1024 AS MaxSizeMB,
    is_percent_growth  AS PercentGrowth,
    type_desc
FROM tempdb.sys.database_files
ORDER BY file_id;
"@
            Invoke-Sqlcmd -ServerInstance $node -Query $q -TrustServerCertificate | Format-Table -AutoSize

            # Compter les fichiers data
            $count = Invoke-Sqlcmd -ServerInstance $node `
                -Query "SELECT COUNT(*) AS Nb FROM tempdb.sys.database_files WHERE type_desc = 'ROWS'" `
                -TrustServerCertificate
            if ($count.Nb -eq 4) {
                Write-Step "$node : 4 fichiers de donnees TempDB" "OK"
            } else {
                Write-Step "$node : $($count.Nb) fichier(s) - attendu : 4" "WARN"
            }
        }
    }

    # --- RESUME ---
    # --- RESUME ---
		Write-Section "Resume"
		Write-Host ""
		Write-Host "  Nodes          : $($TargetNodes -join ', ')" -ForegroundColor Cyan
		Write-Host "  Configuration  : 4 fichiers data (tempdev, temp2, temp3, temp4)" -ForegroundColor Cyan
		Write-Host "  Taille         : 2 GB par fichier (max 8 GB chacun)" -ForegroundColor Cyan
		Write-Host "  FILEGROWTH     : 512 MB (fixe)" -ForegroundColor Cyan
		Write-Host "  Log TempDB     : 512 MB, croissance 256 MB, max 2 GB" -ForegroundColor Cyan
		Write-Host "  Emplacement    : S:\SQL\TempDB\" -ForegroundColor Cyan
		Write-Host ""
		Write-Host "  [OK] TempDB optimise sur les deux noeuds" -ForegroundColor Green
		Write-Host ""
		Write-Host "  [!] IMPORTANT : un redemarrage de MSSQLSERVER est OBLIGATOIRE" -ForegroundColor Yellow
		Write-Host "      pour que les nouveaux fichiers TempDB soient crees." -ForegroundColor Yellow
		Write-Host ""

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
    Write-Host "Log : $TranscriptPath" -ForegroundColor DarkGray
}