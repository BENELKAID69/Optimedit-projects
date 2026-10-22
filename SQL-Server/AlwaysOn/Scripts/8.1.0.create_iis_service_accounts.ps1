<#
    8.1.0.create_iis_service_accounts.ps1
    Objet   : Créer les 13 comptes de service applicatifs (svc_*) dans Active Directory (si absents).
    Noeud   : DC03 - nécessite le module ActiveDirectory
    Note    : Idempotent - ne recrée pas les comptes existants.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Domain = "optimedit.eu",
    [string]$OU     = "OU=Service Accounts,DC=optimedit,DC=eu"
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
# ÉTAPE 2 — Vérification de l'OU cible
# ============================================================
Write-Step "2. Vérification de l'OU cible"

try {
    $null = Get-ADOrganizationalUnit -Identity $OU -ErrorAction Stop
    Write-Ok "OU trouvé : $OU"
} catch {
    Write-Fail "OU introuvable : $OU. Vérifiez le chemin."
    exit 1
}

# ============================================================
# ÉTAPE 3 — Création des 13 comptes (si absents)
# ============================================================
Write-Step "3. Traitement des 13 comptes de service"

$Accounts = @(
    "svc_direction","svc_comptabilite","svc_paie","svc_rh","svc_ce",
    "svc_it","svc_production","svc_formation","svc_achat",
    "svc_commercial","svc_client","svc_juridique","svc_blog"
)

$createdCount = 0
$skippedCount = 0

foreach ($Account in $Accounts) {
    
    # Vérifier si le compte existe déjà
    $ExistingUser = Get-ADUser -Filter "SamAccountName -eq '$Account'" -ErrorAction SilentlyContinue

    if ($ExistingUser) {
        Write-Warn "Compte déjà existant : $Account (ignoré)"
        $skippedCount++
    } else {
        # Le compte n'existe pas, on le crée
        if ($PSCmdlet.ShouldProcess($Account, "Créer le compte AD dans $OU")) {
            try {
                Write-Host "  Création de $Account..." -ForegroundColor Cyan
                $Password = Read-Host -Prompt "  Mot de passe pour $Account" -AsSecureString
                
                New-ADUser -Name $Account -SamAccountName $Account `
                           -UserPrincipalName "$Account@$Domain" `
                           -Path $OU -AccountPassword $Password `
                           -PasswordNeverExpires $true `
                           -CannotChangePassword $true `
                           -Enabled $true
                           
                Write-Ok "Compte créé : $Account"
                $createdCount++
            } catch {
                Write-Fail "Erreur lors de la création de $Account : $($_.Exception.Message)"
            }
        }
    }
}

# ============================================================
# RÉSUMÉ
# ============================================================
Write-Step "Résumé"
Write-Host "  Comptes existants (ignorés) : $skippedCount"
Write-Host "  Comptes créés               : $createdCount"
Write-Host "  Total                       : $($Accounts.Count)"
Write-Host ""

if ($createdCount -eq 0 -and $skippedCount -eq 13) {
    Write-Host "  [OK] Les 13 comptes sont déjà présents dans l'AD. Aucune action requise." -ForegroundColor Green
} else {
    Write-Host "  [OK] Traitement terminé." -ForegroundColor Green
}
Write-Host ""