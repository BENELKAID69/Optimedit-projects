<#
    8.2.0.create_GG_SVC_AppPools.ps1
    Objet   : Vérifier les 13 comptes de service IIS, créer le groupe GG_IIS_AppPools
              et y ajouter les 13 comptes svc_* (si absents).
    Noeud   : DC03 - nécessite le module ActiveDirectory
    Note    : Idempotent - vérifie l'existence du groupe et l'appartenance des membres.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GroupName = "GG_IIS_AppPools",
    [string]$GroupOU   = "OU=Service Accounts,DC=optimedit,DC=eu"
)

# ============================================================
# FONCTIONS UTILITAIRES
# ============================================================
function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "=== $Message ===" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [SKIP] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "  [ECHEC] $Message" -ForegroundColor Red
}

# ============================================================
# ÉTAPE 1 — Vérification du module ActiveDirectory
# ============================================================
Write-Step "1. Vérification du module ActiveDirectory"
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-Ok "Module ActiveDirectory importé."
} catch {
    Write-Fail "Module ActiveDirectory introuvable. Exécutez : Install-WindowsFeature RSAT-AD-PowerShell"
    exit 1
}

# ============================================================
# ÉTAPE 2 — Vérification de l'OU cible du groupe
# ============================================================
Write-Step "2. Vérification de l'OU cible du groupe"
try {
    $null = Get-ADOrganizationalUnit -Identity $GroupOU -ErrorAction Stop
    Write-Ok "OU trouvé : $GroupOU"
} catch {
    Write-Fail "OU introuvable : $GroupOU. Vérifiez le chemin."
    exit 1
}

# ============================================================
# ÉTAPE 3 — Vérification des 13 comptes svc_*
# ============================================================
Write-Step "3. Vérification de l'existence des 13 comptes"

$Accounts = @(
    "svc_direction","svc_comptabilite","svc_paie","svc_rh","svc_ce",
    "svc_it","svc_production","svc_formation","svc_achat",
    "svc_commercial","svc_client","svc_juridique","svc_blog"
)

$Missing = @()
foreach ($Account in $Accounts) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Account'" -ErrorAction SilentlyContinue)) {
        $Missing += $Account
    }
}

if ($Missing.Count -gt 0) {
    Write-Fail "Comptes manquants : $($Missing -join ', '). Exécutez 8.1.0 d'abord."
    exit 1
}
Write-Ok "Les 13 comptes svc_* sont présents."

# ============================================================
# ÉTAPE 4 — Création du groupe de sécurité (si absent)
# ============================================================
Write-Step "4. Vérification et création du groupe $GroupName"

$ExistingGroup = Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue

if ($ExistingGroup) {
    Write-Warn "Groupe déjà existant : $GroupName (ignoré)"
} else {
    if ($PSCmdlet.ShouldProcess($GroupName, "Créer le groupe AD dans $GroupOU")) {
        try {
            New-ADGroup -Name $GroupName -GroupScope Global -GroupCategory Security -Path $GroupOU
            Write-Ok "Groupe créé : $GroupName dans $GroupOU"
        } catch {
            Write-Fail "Erreur lors de la création du groupe : $($_.Exception.Message)"
            exit 1
        }
    }
}

# ============================================================
# ÉTAPE 5 — Ajout des 13 comptes au groupe
# ============================================================
Write-Step "5. Vérification de l'appartenance des comptes au groupe"

$AddedCount   = 0
$SkippedCount = 0

# On récupère l'état actuel des membres (avec gestion d'erreur silencieuse si le groupe n'existe pas encore)
$CurrentMembers = @()
if (Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue) {
    $CurrentMembers = Get-ADGroupMember -Identity $GroupName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
}

foreach ($Account in $Accounts) {
    if ($CurrentMembers -contains $Account) {
        Write-Warn "Membre déjà présent : $Account (ignoré)"
        $SkippedCount++
    } else {
        if ($PSCmdlet.ShouldProcess($Account, "Ajouter au groupe $GroupName")) {
            try {
                Add-ADGroupMember -Identity $GroupName -Members $Account -ErrorAction Stop
                Write-Ok "Compte ajouté : $Account"
                $AddedCount++
            } catch {
                Write-Fail "Erreur lors de l'ajout de $Account : $($_.Exception.Message)"
            }
        }
    }
}

# ============================================================
# ÉTAPE 6 — Vérification finale
# ============================================================
Write-Step "6. Vérification finale du groupe"

$FinalMembers = @()
if (Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue) {
    $FinalMembers = Get-ADGroupMember -Identity $GroupName -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName
}

$FinalCount = $FinalMembers.Count

if ($WhatIfPreference) {
    Write-Host "  [WhatIf] Vérification finale ignorée (le groupe n'est pas encore réellement créé)." -ForegroundColor Yellow
} else {
    Write-Ok "Membres actuels de $GroupName : $FinalCount"
    $FinalMembers | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
}

# ============================================================
# RÉSUMÉ
# ============================================================
Write-Step "Résumé"
Write-Host "  Comptes déjà membres (ignorés) : $SkippedCount"
Write-Host "  Comptes ajoutés au groupe      : $AddedCount"
Write-Host ""

if ($WhatIfPreference) {
    Write-Host "  [WhatIf] Simulation terminée. Relancez sans -WhatIf pour appliquer." -ForegroundColor Yellow
} elseif ($FinalCount -eq 13) {
    Write-Host "  [OK] Le groupe $GroupName contient bien les 13 comptes applicatifs." -ForegroundColor Green
} else {
    Write-Host "  [ATTENTION] Le groupe contient $FinalCount membres au lieu de 13. Vérifiez manuellement." -ForegroundColor Yellow
}
Write-Host ""