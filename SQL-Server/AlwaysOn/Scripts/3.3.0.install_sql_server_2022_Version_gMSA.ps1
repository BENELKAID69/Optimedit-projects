<#
    3.3.0.install_sql_server_2022_Version_gMSA.ps1
    Objet     : Installation automatisée de SQL Server 2022 (édition Developer) avec gMSA.
    Noeuds    : SQLS01 + SQLS02 (exécuter sur chaque nœud, ISO monté en lecteur D:)
    Prérequis : 
      - Clé AES générée sur le nœud (3.0.0.manage_secrets.ps1 -GenerateKey)
      - Comptes AD gMSA_SQL_Server$ et gMSA_SQL_Agent$ créés et configurés (KDS Root Key)
      - Accès Internet pour installer le module SqlServer (si absent)

    PRINCIPE :
    - Vérifie tous les prérequis LOCAUX (clé AES, ISO, répertoires).
    - Vérifie et installe le module SqlServer si nécessaire.
    - La vérification des comptes AD est faite EN AMONT (doit exister dans l'AD).
    - Utilise try/catch pour arrêter proprement en cas d'erreur.
    - Supporte -WhatIf pour simuler sans modifier.
    - Ne demande AUCUN mot de passe pour les comptes de service (géré par l'AD).

    ⚠️ AVERTISSEMENTS IMPORTANTS POUR LE FUTUR PROJET (gMSA) :
    
    1. Tâches de maintenance et alertes
    Le compte gMSA (ex: gMSA_SQL_Agent$) devra avoir les permissions NTFS et les droits 
    nécessaires pour accéder à C:\ProgramData\SQLSecrets\ (pour lire aes.key et les 
    fichiers .enc restants comme TDE et SMTP). Les ACL devront cibler le nom du gMSA 
    (qui se termine par $).
    De plus, si un job SQL Agent exécute un script PowerShell, il le fera sous l'identité 
    du gMSA. Il faudra vérifier que ce compte a bien accès aux partages et aux chemins 
    locaux utilisés.
    
    2. Points de vigilance avec les gMSA et TDE
    - Accès au certificat TDE : Le compte gMSA doit avoir la permission Read sur la clé 
      privée du certificat TDE dans le magasin LocalMachine\My. Sinon, SQL Server ne 
      pourra pas déchiffrer les bases.
    - SPN et Kerberos : Les SPN (MSSQLSvc/...) doivent être enregistrés sur le compte gMSA, 
      et non sur le compte de l'ordinateur. Tous les réplicas de l'AG doivent utiliser le 
      même compte gMSA pour que Kerberos fonctionne avec le Listener.
    - Les secrets tde-masterkey-pwd, tde-cert-pwd, smtp-ovh-pwd doivent continuer à être 
      générés et chiffrés normalement via 3.0.0.manage_secrets.ps1.

    EXEMPLES D'EXÉCUTION :

    # Simulation (aucune modification)
    .\3.3.0.install_sql_server_2022_Version_gMSA.ps1 -WhatIf

    # Exécution réelle
    .\3.3.0.install_sql_server_2022_Version_gMSA.ps1
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$SecureFolder     = "C:\ProgramData\SQLSecrets",
    [string]$IsoDrive         = "D:",
    [string]$SqlEngineAccount = "optimedit\gMSA_SQL_Server$",
    [string]$SqlAgentAccount  = "optimedit\gMSA_SQL_Agent$",
    [string]$SysAdminAccount  = "optimedit\Administrateur"
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

function Write-Fail {
    param([string]$Message)
    Write-Host "  [ECHEC] $Message" -ForegroundColor Red
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [AVERTISSEMENT] $Message" -ForegroundColor Yellow
}

# ============================================================
# ÉTAPE 1 — Vérification de la clé AES (pour les autres secrets)
# ============================================================
Write-Step "1. Vérification de la clé AES"
# Note : Avec gMSA, le secret sql-service-pwd.enc n'est plus nécessaire.
# Mais la clé AES reste requise pour les autres secrets (TDE, SMTP) configurés plus tard.

$KeyPath = Join-Path $SecureFolder "aes.key"

try {
    if (!(Test-Path $KeyPath)) {
        throw "Clé AES introuvable : $KeyPath"
    }
    $keySize = (Get-Item $KeyPath).Length
    if ($keySize -ne 32) {
        throw "Clé AES invalide : $keySize octets (attendu 32)"
    }
    Write-Ok "Clé AES : $KeyPath ($keySize octets)"
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}

# ============================================================
# ÉTAPE 2 — Vérification et installation du module SqlServer
# ============================================================
Write-Step "2. Vérification du module PowerShell SqlServer"

try {
    $SqlServerModule = Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue

    if ($SqlServerModule) {
        Write-Ok "Module SqlServer déjà installé (version $($SqlServerModule.Version))"
    } else {
        Write-Warn "Module SqlServer absent. Installation nécessaire."

        Write-Host "  Vérification de l'accès à www.powershellgallery.com:443..." -ForegroundColor Gray
        try {
            $NetTest = Test-NetConnection -ComputerName "www.powershellgallery.com" -Port 443 -WarningAction SilentlyContinue
            if (-not $NetTest.TcpTestSucceeded) {
                throw "Accès à www.powershellgallery.com:443 impossible"
            }
            Write-Ok "Accès à PowerShell Gallery confirmé"
        } catch {
            Write-Warn "Impossible d'accéder à PowerShell Gallery : $($_.Exception.Message)"
            Write-Host "  → Le module SqlServer ne pourra pas être installé automatiquement." -ForegroundColor Yellow
            Write-Host "  → Installer le module manuellement : Install-Module -Name SqlServer -Scope AllUsers -Force" -ForegroundColor Yellow
        }

        if ($NetTest.TcpTestSucceeded) {
            try {
                Write-Host "  Installation du module SqlServer..." -ForegroundColor Cyan
                Install-Module -Name SqlServer -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
                Write-Ok "Module SqlServer installé avec succès"
            } catch {
                Write-Warn "Échec de l'installation du module SqlServer : $($_.Exception.Message)"
            }
        }
    }
} catch {
    Write-Warn "Erreur lors de la vérification du module SqlServer : $($_.Exception.Message)"
}

# ============================================================
# ÉTAPE 3 — Vérification LOCALE des comptes gMSA
# ============================================================
Write-Step "3. Vérification locale des comptes gMSA"

try {
    $engineSid = (New-Object System.Security.Principal.NTAccount($SqlEngineAccount)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Ok "Compte résolvable : $SqlEngineAccount (SID $engineSid)"
} catch {
    Write-Fail "Compte non résolvable localement : $SqlEngineAccount"
    Write-Host "  → Vérifier que le gMSA existe dans AD et que la KDS Root Key est configurée." -ForegroundColor Yellow
    exit 1
}

try {
    $agentSid = (New-Object System.Security.Principal.NTAccount($SqlAgentAccount)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Ok "Compte résolvable : $SqlAgentAccount (SID $agentSid)"
} catch {
    Write-Fail "Compte non résolvable localement : $SqlAgentAccount"
    Write-Host "  → Vérifier que le gMSA existe dans AD et que la KDS Root Key est configurée." -ForegroundColor Yellow
    exit 1
}

try {
    $sysadminSid = (New-Object System.Security.Principal.NTAccount($SysAdminAccount)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Ok "Compte SysAdmin résolvable : $SysAdminAccount (SID $sysadminSid)"
} catch {
    Write-Fail "Compte SysAdmin non résolvable : $SysAdminAccount"
    exit 1
}

# ============================================================
# ÉTAPE 4 — Vérification des répertoires SQL
# ============================================================
Write-Step "4. Vérification des répertoires SQL"

$SqlDirs = @("S:\SQL\Data", "S:\SQL\Log", "S:\SQL\Backup", "S:\SQL\TempDB")
foreach ($Dir in $SqlDirs) {
    if (!(Test-Path $Dir)) {
        Write-Fail "Répertoire introuvable : $Dir"
        exit 1
    }
    Write-Ok "Répertoire : $Dir"
}

# ============================================================
# ÉTAPE 5 — Vérification de l'ISO SQL Server
# ============================================================
Write-Step "5. Vérification de l'ISO SQL Server"

$SetupExe   = Join-Path $IsoDrive "Setup.exe"
$DefaultIni = Join-Path $IsoDrive "x64\DefaultSetup.ini"

try {
    if (!(Test-Path $SetupExe)) {
        throw "Setup.exe introuvable : $SetupExe"
    }
    Write-Ok "Setup.exe : $SetupExe"

    if (!(Test-Path $DefaultIni)) {
        throw "DefaultSetup.ini introuvable : $DefaultIni (ISO incomplet ?)"
    }
    Write-Ok "DefaultSetup.ini : $DefaultIni"

    $PidLine = Get-Content $DefaultIni | Select-String "PID="
    Write-Ok "PID détecté : $($PidLine.Line)"
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}

# ============================================================
# ÉTAPE 6 — Vérification qu'aucune instance SQL n'existe
# ============================================================
Write-Step "6. Vérification des instances SQL existantes"

$ExistingService = Get-Service -Name "MSSQLSERVER" -ErrorAction SilentlyContinue
if ($ExistingService) {
    Write-Fail "Le service MSSQLSERVER existe déjà. Désinstaller SQL Server avant de continuer."
    exit 1
}
Write-Ok "Aucune instance SQL Server existante"

# ============================================================
# ÉTAPE 7 — Construction des arguments d'installation
# ============================================================
Write-Step "7. Construction des arguments d'installation"

$TempDbFileCount = [Math]::Min((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors, 8)

$Args = @(
    "/Q",
    "/ACTION=Install",
    "/IACCEPTSQLSERVERLICENSETERMS",
    "/FEATURES=SQLENGINE",
    "/INSTANCENAME=MSSQLSERVER",
    "/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS",
    "/SQLSVCACCOUNT=$SqlEngineAccount",
    # PAS de /SQLSVCPASSWORD pour gMSA
    "/AGTSVCACCOUNT=$SqlAgentAccount",
    # PAS de /AGTSVCPASSWORD pour gMSA
    "/AGTSVCSTARTUPTYPE=Automatic",
    "/SQLSYSADMINACCOUNTS=`"$SysAdminAccount`"",
    "/INSTALLSQLDATADIR=S:\SQL\Data",
    "/SQLUSERDBLOGDIR=S:\SQL\Log",
    "/SQLBACKUPDIR=S:\SQL\Backup",
    "/SQLTEMPDBDIR=S:\SQL\TempDB",
    #"/SQLTEMPDBFILECOUNT=8",           # <<< : 8 fichiers TempDB (aligne sur 8 CPU logiques) - Adapter ---------------------
	"/SQLTEMPDBFILECOUNT=$TempDbFileCount", # avec cette la valeur est géré dynamiquement
    "/SQLTEMPDBFILESIZE=2048",
    "/SQLTEMPDBFILEGROWTH=512",
    "/TCPENABLED=1",
    "/NPENABLED=0"
)

Write-Ok "Nombre d'arguments : $($Args.Count)"
Write-Host "  Arguments :" -ForegroundColor Gray
$Args | ForEach-Object {
    Write-Host "    $_" -ForegroundColor Gray
}

# ============================================================
# ÉTAPE 8 — Lancement de l'installation
# ============================================================
Write-Step "8. Lancement de l'installation"

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Installer SQL Server 2022 Developer (gMSA)")) {
    try {
        Write-Host "  Lancement de setup.exe..." -ForegroundColor Cyan
        $proc = Start-Process -FilePath $SetupExe -ArgumentList $Args -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -ne 0) {
            throw "setup.exe a retourné le code $($proc.ExitCode)"
        }
        Write-Ok "Installation terminée avec succès (code 0)"
    } catch {
        Write-Fail "Échec de l'installation : $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Host "  [WhatIf] setup.exe serait lancé avec les arguments ci-dessus." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Vérifier le résumé dans : %ProgramFiles%\Microsoft SQL Server\160\Setup Bootstrap\Log\" -ForegroundColor Cyan
Write-Host "Installation terminée." -ForegroundColor Green