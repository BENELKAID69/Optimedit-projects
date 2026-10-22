<#
.SYNOPSIS
    Crée et configure le partage ClusterWitness pour le quorum du cluster CL-SQL-AG.

.DESCRIPTION
    Ce script crée le dossier P:\ClusterWitness, le partage SMB ClusterWitness,
    et accorde les droits NTFS (Modify) et SMB (Change) au compte ordinateur
    du cluster CL-SQL-AG$.

    NOUVEAUTÉ v5 :
    - Résolution automatique du SID du compte cluster depuis Active Directory via LDAP.
    - Plus besoin de récupérer le SID manuellement sur le DC.
    - Support de -ClusterSID en override (si vous voulez forcer un SID spécifique).

    Le script est idempotent : il peut être réexécuté sans effet secondaire.
    Il supporte -WhatIf pour la prévisualisation.
    Compatible Windows PowerShell 5.1 et PowerShell 7+.

.PARAMETER WitnessPath
    Chemin local du dossier témoin. Défaut : P:\ClusterWitness

.PARAMETER ShareName
    Nom du partage SMB. Défaut : ClusterWitness

.PARAMETER ClusterName
    Nom du cluster (sans le $). Défaut : CL-SQL-AG
    Le script résoudra automatiquement le SID du compte CL-SQL-AG$ dans AD.

.PARAMETER ClusterSID
    (Optionnel) SID du compte ordinateur du cluster, si vous voulez le forcer.
    Si non fourni, le script le résout automatiquement via LDAP.

.PARAMETER DomainController
    FQDN du contrôleur de domaine pour la résolution SID→Nom.
    Défaut : DC03.optimedit.eu

.PARAMETER MinFreeSpaceGB
    Espace libre minimum requis sur le volume (en GB). Défaut : 1

.PARAMETER Force
    Force la réapplication des droits même s'ils existent déjà.

.PARAMETER LogPath
    Chemin du fichier de log. Défaut : .\4.3.1.create_cluster_witness_share.log

.EXAMPLE
    # Résolution automatique du SID (recommandé)
    .\4.3.1.create_cluster_witness_share_v5.ps1

.EXAMPLE
    # Prévisualisation
    .\4.3.1.create_cluster_witness_share_v5.ps1 -WhatIf

.EXAMPLE
    # Forcer un SID spécifique
    .\4.3.1.create_cluster_witness_share_v5.ps1 -ClusterSID "S-1-5-21-...-1231"

.NOTES
    Auteur    : Projet AlwaysOn
    Version   : 5.0
    Nœud      : OPT-FS03 (exécuter localement, en administrateur)
    Prérequis :
      - Le cluster CL-SQL-AG doit exister dans AD (créé par 4.3.0)
      - Le volume P: doit exister avec au moins 1 GB libre
      - Accès réseau à un contrôleur de domaine (LDAP port 389)
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$WitnessPath = "P:\ClusterWitness",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ShareName = "ClusterWitness",

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ClusterName = "CL-SQL-AG",

    [Parameter(Mandatory = $false)]
    [string]$ClusterSID = "",

    [Parameter(Mandatory = $false)]
    [string]$DomainController = "DC03.optimedit.eu",

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 1024)]
    [int]$MinFreeSpaceGB = 1,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = ".\4.3.1.create_cluster_witness_share.log"
)

# ============================================================
# INITIALISATION
# ============================================================
$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:Errors = @()
$script:Warnings = @()

# Démarrer la transcription pour la traçabilité
try {
    Start-Transcript -Path $LogPath -Append -Force | Out-Null
    Write-Verbose "Log démarré : $LogPath"
} catch {
    Write-Warning "Impossible de démarrer la transcription : $($_.Exception.Message)"
}

# ============================================================
# FONCTIONS AUXILIAIRES
# ============================================================

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "INFO"  { "Cyan" }
        default { "White" }
    }
    $prefix = switch ($Status) {
        "OK"    { "[OK]   " }
        "WARN"  { "[WARN] " }
        "ERROR" { "[ERR]  " }
        "INFO"  { "[INFO] " }
        default { "[----] " }
    }
    Write-Host "$prefix$Message" -ForegroundColor $color
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ClusterComputerSID {
    <#
    .SYNOPSIS
        Résout le SID d'un compte ordinateur dans Active Directory via LDAP.
    .DESCRIPTION
        Interroge directement AD via System.DirectoryServices.DirectorySearcher,
        sans dépendre du module RSAT. Fonctionne depuis n'importe quel serveur
        membre du domaine, y compris OPT-FS03.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $false)]
        [string]$DomainController = ""
    )

    try {
        # Déterminer le contexte LDAP
        if ([string]::IsNullOrWhiteSpace($DomainController)) {
            # Utiliser le domaine courant
            $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
            $ldapPath = "LDAP://$($domain.Name)"
            Write-Verbose "LDAP path (domaine courant) : $ldapPath"
        } else {
            # Utiliser le DC spécifié
            $ldapPath = "LDAP://$DomainController"
            Write-Verbose "LDAP path (DC spécifié) : $ldapPath"
        }

        # Créer le searcher
        $root = New-Object System.DirectoryServices.DirectoryEntry($ldapPath)
        $searcher = New-Object System.DirectoryServices.DirectorySearcher($root)

        # Filtrer sur le compte ordinateur (nom sans le $ ou avec)
        $searcher.Filter = "(&(objectClass=computer)(cn=$ComputerName))"
        $searcher.PropertiesToLoad.Add("objectsid") | Out-Null
        $searcher.PropertiesToLoad.Add("cn") | Out-Null
        $searcher.PropertiesToLoad.Add("distinguishedname") | Out-Null

        Write-Verbose "Recherche LDAP : $($searcher.Filter)"

        $result = $searcher.FindOne()

        if (-not $result) {
            Write-Verbose "Aucun résultat pour '$ComputerName'"
            return $null
        }

        # Extraire le SID
        $sidBytes = $result.Properties["objectsid"][0]
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)

        Write-Verbose "Compte trouvé : $($result.Properties['distinguishedname'][0])"
        Write-Verbose "SID : $($sid.Value)"

        return $sid.Value

    } catch {
        Write-Verbose "Erreur lors de la résolution LDAP : $($_.Exception.Message)"
        return $null
    }
}

function Resolve-SidToName {
    <#
    .SYNOPSIS
        Résout un SID en nom de compte (avec fallback WMI sur le DC).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SidString,

        [Parameter(Mandatory = $false)]
        [string]$DC = ""
    )

    # Tentative 1 : résolution locale via .NET
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($SidString)
        $name = $sid.Translate([System.Security.Principal.NTAccount]).Value
        Write-Verbose "SID résolu localement : $name"
        return $name
    } catch {
        Write-Verbose "Résolution locale échouée : $($_.Exception.Message)"
    }

    # Tentative 2 : résolution via WMI sur le DC
    if (-not [string]::IsNullOrWhiteSpace($DC)) {
        try {
            Write-Verbose "Tentative via WMI sur $DC..."
            $wmi = Get-WmiObject -Class Win32_SID -ComputerName $DC `
                -Filter "SID='$SidString'" -ErrorAction Stop
            if ($wmi -and $wmi.AccountName) {
                Write-Verbose "SID résolu via WMI : $($wmi.AccountName)"
                return $wmi.AccountName
            }
        } catch {
            Write-Verbose "Résolution WMI échouée : $($_.Exception.Message)"
        }
    }

    return $null
}

function Test-VolumeSpace {
    <#
    .SYNOPSIS
        Vérifie que le volume cible dispose d'un espace libre suffisant.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$MinFreeSpaceGB
    )

    try {
        $drive = Split-Path -Qualifier $Path -ErrorAction Stop
        $letter = $drive.TrimEnd(':')
        $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop

        $freeGB = [math]::Round($volume.SizeRemaining / 1GB, 2)
        Write-Verbose "Volume ${letter}: libre = $freeGB GB (requis : $MinFreeSpaceGB GB)"

        if ($freeGB -lt $MinFreeSpaceGB) {
            Write-Step "Espace libre insuffisant sur ${letter}: ($freeGB GB < $MinFreeSpaceGB GB)" "ERROR"
            return $false
        }
        Write-Step "Volume ${letter}: OK ($freeGB GB libre)" "OK"
        return $true
    } catch {
        Write-Step "Impossible de vérifier le volume : $($_.Exception.Message)" "ERROR"
        return $false
    }
}

# ============================================================
# BLOC PRINCIPAL
# ============================================================
try {
    Write-Section "4.3.1 - Création du partage ClusterWitness (v5.0)"
    Write-Host " Serveur       : $env:COMPUTERNAME" -ForegroundColor Gray
    Write-Host " Date          : $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')" -ForegroundColor Gray
    Write-Host " PowerShell    : $($PSVersionTable.PSVersion)" -ForegroundColor Gray
    Write-Host " Mode          : $(if ($WhatIfPreference) { 'WhatIf (prévisualisation)' } else { 'Exécution réelle' })" -ForegroundColor Gray
    Write-Host " Log           : $LogPath" -ForegroundColor Gray

    # --------------------------------------------------------
    # PRÉ-VOL 0 : Vérifier les privilèges administrateur
    # --------------------------------------------------------
    Write-Section "Pré-vol : Vérification des privilèges"
    if (-not (Test-IsAdministrator)) {
        throw "Ce script doit être exécuté en tant qu'administrateur local."
    }
    Write-Step "Privilèges administrateur confirmés" "OK"

    # --------------------------------------------------------
    # PRÉ-VOL 1 : Déterminer le SID du compte cluster
    # --------------------------------------------------------
    Write-Section "Étape 1/6 : Détermination du SID du compte cluster"

    $SidObject = $null
    $ResolvedSID = $null
    $ResolvedName = $null

    # Cas 1 : SID fourni manuellement
    if (-not [string]::IsNullOrWhiteSpace($ClusterSID)) {
        Write-Step "SID fourni manuellement : $ClusterSID" "INFO"
        try {
            $SidObject = New-Object System.Security.Principal.SecurityIdentifier($ClusterSID)
            $ResolvedSID = $ClusterSID
            Write-Step "Format du SID valide" "OK"
        } catch {
            throw "Le SID fourni est invalide : $ClusterSID"
        }
    }
    # Cas 2 : Résolution automatique via LDAP
    else {
        Write-Step "Résolution automatique du SID pour '$ClusterName$' via LDAP..." "INFO"
        Write-Step "Contrôleur de domaine : $DomainController" "INFO"

        $ResolvedSID = Get-ClusterComputerSID -ComputerName $ClusterName -DomainController $DomainController

        if ($ResolvedSID) {
            Write-Step "SID résolu : $ResolvedSID" "OK"
            $SidObject = New-Object System.Security.Principal.SecurityIdentifier($ResolvedSID)
        } else {
            throw "Impossible de résoudre le SID du compte '$ClusterName$' dans AD. Vérifiez que le cluster existe (script 4.3.0) et que '$DomainController' est joignable."
        }
    }

    # Résoudre le nom (nécessaire pour Grant-SmbShareAccess)
    Write-Step "Résolution du nom pour le partage SMB..." "INFO"
    $ResolvedName = Resolve-SidToName -SidString $ResolvedSID -DC $DomainController

    if ($ResolvedName) {
        Write-Step "Nom résolu : $ResolvedName" "OK"
    } else {
        Write-Step "Nom non résolu. Le partage SMB devra être configuré manuellement." "WARN"
        $script:Warnings += "SID non résolu en nom de compte"
    }

    # Préparer le nom d'affichage (compatible PowerShell 5.1)
    $displayName = if ($ResolvedName) { $ResolvedName } else { $ResolvedSID }

    # --------------------------------------------------------
    # PRÉ-VOL 2 : Vérifier le volume et l'espace libre
    # --------------------------------------------------------
    Write-Section "Étape 2/6 : Vérification du volume cible"

    if ($PSCmdlet.ShouldProcess("Volume P:", "Vérifier existence et espace")) {
        $drive = Split-Path -Qualifier $WitnessPath -ErrorAction SilentlyContinue
        if (-not $drive) {
            throw "Impossible de déterminer le volume pour le chemin '$WitnessPath'."
        }

        $letter = $drive.TrimEnd(':')
        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue

        if (-not $volume) {
            throw "Le volume ${letter}: n'existe pas sur ce serveur."
        }
        Write-Step "Volume ${letter}: trouvé" "OK"

        # Vérification de l'espace libre
        if (-not (Test-VolumeSpace -Path $WitnessPath -MinFreeSpaceGB $MinFreeSpaceGB)) {
            throw "Espace libre insuffisant sur ${letter}: (minimum requis : $MinFreeSpaceGB GB)."
        }
    }

    # --------------------------------------------------------
    # ÉTAPE 3 : Création du dossier local
    # --------------------------------------------------------
    Write-Section "Étape 3/6 : Création du dossier local"

    if (Test-Path $WitnessPath) {
        Write-Step "Dossier $WitnessPath : déjà présent" "WARN"
    } else {
        if ($PSCmdlet.ShouldProcess($WitnessPath, "Créer le dossier")) {
            New-Item -Path $WitnessPath -ItemType Directory -Force | Out-Null
            Write-Step "Dossier créé : $WitnessPath" "OK"
        }
    }

    # --------------------------------------------------------
    # ÉTAPE 4 : Création du partage SMB
    # --------------------------------------------------------
    Write-Section "Étape 4/6 : Création du partage SMB"

    $ExistingShare = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue

    if ($ExistingShare) {
        Write-Step "Partage $ShareName : déjà présent" "WARN"

        if ($ExistingShare.Path -ne $WitnessPath) {
            Write-Step "ATTENTION : Le partage pointe vers '$($ExistingShare.Path)' au lieu de '$WitnessPath'" "WARN"
            $script:Warnings += "Chemin du partage différent de celui attendu"
        }
    } else {
        if ($PSCmdlet.ShouldProcess("\\$env:COMPUTERNAME\$ShareName", "Créer le partage SMB")) {
            New-SmbShare -Name $ShareName -Path $WitnessPath `
                -FullAccess "Administrateurs" -ErrorAction Stop | Out-Null
            Write-Step "Partage créé : \\$env:COMPUTERNAME\$ShareName" "OK"
        }
    }

    # --------------------------------------------------------
    # ÉTAPE 5 : Droits NTFS (via SID, toujours fiable)
    # --------------------------------------------------------
    Write-Section "Étape 5/6 : Attribution des droits NTFS"

    if ($PSCmdlet.ShouldProcess($WitnessPath, "Accorder NTFS Modify à $displayName")) {
        try {
            $acl = Get-Acl -Path $WitnessPath

            $existingRule = $acl.Access | Where-Object {
                $_.IdentityReference.Value -eq $ResolvedSID -or
                $_.IdentityReference -like "*$ClusterName*"
            }

            if ($existingRule -and -not $Force) {
                Write-Step "Droits NTFS : déjà présents pour le compte du cluster" "WARN"
            } else {
                if ($existingRule -and $Force) {
                    Write-Step "Droits NTFS : réapplication forcée (-Force)" "INFO"
                    $acl.RemoveAccessRuleAll($existingRule) | Out-Null
                }

                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $SidObject,
                    "Modify",
                    "ContainerInherit,ObjectInherit",
                    "None",
                    "Allow"
                )
                $acl.SetAccessRule($rule)
                Set-Acl -Path $WitnessPath -AclObject $acl
                Write-Step "Droits NTFS accordés (Modify)" "OK"
            }
        } catch {
            throw "Échec de l'attribution des droits NTFS : $($_.Exception.Message)"
        }
    }

    # --------------------------------------------------------
    # ÉTAPE 6 : Droits SMB (via Nom résolu)
    # --------------------------------------------------------
    Write-Section "Étape 6/6 : Attribution des droits SMB"

    if ($ResolvedName) {
        try {
            $currentAccess = Get-SmbShareAccess -Name $ShareName -ErrorAction SilentlyContinue
            $alreadyGranted = $currentAccess | Where-Object { $_.AccountName -eq $ResolvedName }

            if ($alreadyGranted -and -not $Force) {
                Write-Step "Droits SMB : déjà présents pour $ResolvedName" "WARN"
            } else {
                if ($alreadyGranted -and $Force) {
                    Write-Step "Droits SMB : révocation avant réapplication (-Force)" "INFO"
                    Revoke-SmbShareAccess -Name $ShareName -AccountName $ResolvedName -Force -ErrorAction SilentlyContinue
                }

                if ($PSCmdlet.ShouldProcess("\\$env:COMPUTERNAME\$ShareName", "Accorder SMB Change à $ResolvedName")) {
                    Grant-SmbShareAccess -Name $ShareName -AccountName $ResolvedName `
                        -AccessRight Change -Force -ErrorAction Stop | Out-Null
                    Write-Step "Droits SMB accordés (Change) à $ResolvedName" "OK"
                }
            }
        } catch {
            $script:Errors += "Droits SMB : $($_.Exception.Message)"
            Write-Step "Échec de l'attribution des droits SMB : $($_.Exception.Message)" "ERROR"
        }
    } else {
        Write-Step "Droits SMB : ignorés (nom non résolu)" "WARN"
    }

    # --------------------------------------------------------
    # VÉRIFICATION POST-EXÉCUTION
    # --------------------------------------------------------
    Write-Section "Vérification post-exécution"

    $verifOK = $true

    # 1. Dossier
    if (Test-Path $WitnessPath) {
        Write-Step "Dossier $WitnessPath : OK" "OK"
    } else {
        Write-Step "Dossier $WitnessPath : ABSENT" "ERROR"
        $verifOK = $false
    }

    # 2. Partage SMB
    $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($share) {
        Write-Step "Partage $ShareName : OK (chemin : $($share.Path))" "OK"
    } else {
        Write-Step "Partage $ShareName : ABSENT" "ERROR"
        $verifOK = $false
    }

    # 3. Droits SMB
    if ($ResolvedName) {
        $smbAccess = Get-SmbShareAccess -Name $ShareName -ErrorAction SilentlyContinue |
                     Where-Object { $_.AccountName -eq $ResolvedName -and $_.AccessRight -eq "Change" }
        if ($smbAccess) {
            Write-Step "Droits SMB ($ResolvedName, Change) : OK" "OK"
        } else {
            Write-Step "Droits SMB ($ResolvedName, Change) : ABSENTS" "ERROR"
            $verifOK = $false
        }
    }

    # 4. Droits NTFS
    $ntfsAccess = Get-Acl -Path $WitnessPath -ErrorAction SilentlyContinue |
                  Select-Object -ExpandProperty Access |
                  Where-Object { $_.IdentityReference.Value -eq $ResolvedSID -or $_.IdentityReference -like "*$ClusterName*" }
    if ($ntfsAccess) {
        $rights = $ntfsAccess.FileSystemRights | Select-Object -First 1
        Write-Step "Droits NTFS ($($ntfsAccess.IdentityReference), $rights) : OK" "OK"
    } else {
        Write-Step "Droits NTFS : ABSENTS" "ERROR"
        $verifOK = $false
    }

    # --------------------------------------------------------
    # RÉSUMÉ FINAL
    # --------------------------------------------------------
    $duration = (Get-Date) - $script:StartTime

    Write-Section "Résumé de la configuration"

    Write-Host ""
    Write-Host "  Statut global   : $(if ($verifOK -and $script:Errors.Count -eq 0) { 'SUCCÈS' } else { 'AVERTISSEMENTS / ERREURS' })" `
        -ForegroundColor $(if ($verifOK -and $script:Errors.Count -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host "  Durée           : $([math]::Round($duration.TotalSeconds, 2)) secondes" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Chemin local    : $WitnessPath" -ForegroundColor Cyan
    Write-Host "  Partage SMB     : \\$env:COMPUTERNAME\$ShareName" -ForegroundColor Cyan
    Write-Host "  Compte cluster  : $displayName" -ForegroundColor Cyan
    Write-Host "  SID             : $ResolvedSID" -ForegroundColor Cyan
    Write-Host ""

    if ($script:Warnings.Count -gt 0) {
        Write-Host "  Avertissements :" -ForegroundColor Yellow
        $script:Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        Write-Host ""
    }

    if ($script:Errors.Count -gt 0) {
        Write-Host "  Erreurs :" -ForegroundColor Red
        $script:Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host ""
    }

    Write-Host "  Prochaine étape :" -ForegroundColor Yellow
    Write-Host "    Set-ClusterQuorum -FileShareWitness \\$env:COMPUTERNAME\$ShareName" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Exécuter cette commande sur SQLS01 ou SQLS02." -ForegroundColor Gray
    Write-Host ""

    if ($script:Errors.Count -gt 0) {
        exit 1
    }

} catch {
    Write-Section "ERREUR FATALE"
    Write-Host "  Message : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Ligne   : $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    Write-Host "  Script  : $($_.InvocationInfo.ScriptName)" -ForegroundColor Red
    Write-Host ""

    if ($_.ScriptStackTrace) {
        Write-Host "  Stack trace :" -ForegroundColor DarkRed
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
    }

    $script:Errors += $_.Exception.Message
    exit 1

} finally {
    try {
        Stop-Transcript | Out-Null
    } catch {
        # Ignorer
    }

    Write-Host "Log complet : $LogPath" -ForegroundColor DarkGray
}