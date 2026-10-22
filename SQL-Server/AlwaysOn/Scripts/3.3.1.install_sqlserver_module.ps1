<#
    3.3.1.install_sqlserver_module.ps1
    Objet   : Vérifier et installer le module PowerShell SqlServer.
    Noeuds  : SQLS01 + SQLS02
    Prérequis : Accès Internet (pour télécharger le module)

    PRINCIPE :
    - Vérifie si le module SqlServer est déjà installé.
    - Si absent et Internet disponible, l'installe.
    - Si Internet indisponible, affiche un avertissement et continue.

    EXEMPLES D'EXÉCUTION :

    .\3.3.1.install_sqlserver_module.ps1
#>

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
    Write-Host "  [AVERTISSEMENT] $Message" -ForegroundColor Yellow
}

Write-Step "Vérification du module PowerShell SqlServer"

try {
    $SqlServerModule = Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue

    if ($SqlServerModule) {
        Write-Ok "Module SqlServer déjà installé (version $($SqlServerModule.Version))"
        exit 0
    }

    Write-Warn "Module SqlServer absent. Installation nécessaire."

    # --- Vérifier l'accès à PowerShell Gallery ---
    Write-Host "  Vérification de l'accès à www.powershellgallery.com:443..." -ForegroundColor Gray
    $NetTest = Test-NetConnection -ComputerName "www.powershellgallery.com" -Port 443 -WarningAction SilentlyContinue

    if (-not $NetTest.TcpTestSucceeded) {
        Write-Warn "Impossible d'accéder à PowerShell Gallery"
        Write-Host "  → Installer le module manuellement : Install-Module -Name SqlServer -Scope AllUsers -Force" -ForegroundColor Yellow
        exit 1
    }

    Write-Ok "Accès à PowerShell Gallery confirmé"

    # --- Installer le module ---
    Write-Host "  Installation du module SqlServer..." -ForegroundColor Cyan
    Install-Module -Name SqlServer -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    Write-Ok "Module SqlServer installé avec succès"

} catch {
    Write-Warn "Erreur : $($_.Exception.Message)"
    exit 1
}