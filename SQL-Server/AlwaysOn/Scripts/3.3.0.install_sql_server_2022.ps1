<#
    3.3.0.install_sql_server_2022.ps1
    Objet     : Installation automatisée de SQL Server 2022 (édition Developer).
    Noeuds    : SQLS01 + SQLS02 (exécuter sur chaque nœud, ISO monté en lecteur D:)
    Prérequis : 
      - Clé AES générée sur le nœud (3.0.0.manage_secrets.ps1 -GenerateKey)
      - Secret "sql-service-pwd" chiffré sur le nœud
      - Comptes AD SVC_SQL_Engine et SVC_SQL_Agent créés (3.2.0 sur DC03)
      - Accès Internet pour installer le module SqlServer (si absent)

    PRINCIPE :
    - Vérifie tous les prérequis LOCAUX (secrets, ISO, répertoires).
    - Vérifie et installe le module SqlServer si nécessaire.
    - La vérification des comptes AD est faite EN AMONT sur DC03 (3.2.0).
    - Utilise try/catch pour arrêter proprement en cas d'erreur.
    - Supporte -WhatIf pour simuler sans modifier.

    EXEMPLES D'EXÉCUTION :

    # Simulation (aucune modification)
    .\3.3.0.install_sql_server_2022.ps1 -WhatIf

    # Exécution réelle
    .\3.3.0.install_sql_server_2022.ps1
	
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$SecureFolder     = "C:\ProgramData\SQLSecrets",
    [string]$IsoDrive         = "D:",
    [string]$SqlEngineAccount = "optimedit\SVC_SQL_Engine",
    [string]$SqlAgentAccount  = "optimedit\SVC_SQL_Agent",
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
# ÉTAPE 1 — Vérification des fichiers de secrets
# ============================================================
Write-Step "1. Vérification des secrets"

$KeyPath        = Join-Path $SecureFolder "aes.key"
$ServiceEncPath = Join-Path $SecureFolder "sql-service-pwd.enc"

try {
    if (!(Test-Path $KeyPath)) {
        throw "Clé AES introuvable : $KeyPath"
    }
    $keySize = (Get-Item $KeyPath).Length
    if ($keySize -ne 32) {
        throw "Clé AES invalide : $keySize octets (attendu 32)"
    }
    Write-Ok "Clé AES : $KeyPath ($keySize octets)"

    if (!(Test-Path $ServiceEncPath)) {
        throw "Secret introuvable : $ServiceEncPath"
    }
    Write-Ok "Secret chiffré : $ServiceEncPath"
} catch {
    Write-Fail $_.Exception.Message
    exit 1
}

# ============================================================
# ÉTAPE 2 — Déchiffrement du secret en mémoire
# ============================================================
Write-Step "2. Déchiffrement du secret"

try {
    $key       = Get-Content $KeyPath -Encoding Byte
    $securePwd = Get-Content $ServiceEncPath | ConvertTo-SecureString -Key $key
    $bstr      = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
    $plainPwd  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    Write-Ok "Secret déchiffré en mémoire ($($plainPwd.Length) caractères)"
} catch {
    Write-Fail "Échec du déchiffrement : $($_.Exception.Message)"
    exit 1
}

# ============================================================
# ÉTAPE 2bis — Vérification et installation du module SqlServer
# ============================================================
Write-Step "2bis. Vérification du module PowerShell SqlServer"

try {
    # --- Vérifier si le module SqlServer est déjà installé ---
    $SqlServerModule = Get-Module -ListAvailable -Name SqlServer -ErrorAction SilentlyContinue

    if ($SqlServerModule) {
        Write-Ok "Module SqlServer déjà installé (version $($SqlServerModule.Version))"
    } else {
        Write-Warn "Module SqlServer absent. Installation nécessaire."

        # --- Vérifier l'accès à PowerShell Gallery ---
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
            Write-Host "  → L'installation de SQL Server peut continuer sans ce module." -ForegroundColor Yellow
        }

        # --- Installer le module SqlServer ---
        if ($NetTest.TcpTestSucceeded) {
            try {
                Write-Host "  Installation du module SqlServer..." -ForegroundColor Cyan
                Install-Module -Name SqlServer -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
                Write-Ok "Module SqlServer installé avec succès"
            } catch {
                Write-Warn "Échec de l'installation du module SqlServer : $($_.Exception.Message)"
                Write-Host "  → L'installation de SQL Server peut continuer sans ce module." -ForegroundColor Yellow
            }
        }
    }
} catch {
    Write-Warn "Erreur lors de la vérification du module SqlServer : $($_.Exception.Message)"
    Write-Host "  → L'installation de SQL Server peut continuer sans ce module." -ForegroundColor Yellow
}

# ============================================================
# ÉTAPE 3 — Vérification LOCALE des comptes de service
# ============================================================
# Note : on ne fait PAS de requête AD ici (pas de module ActiveDirectory), vérification sur machine admin.
# On vérifie juste que les comptes sont résolvables localement (cache domaine).
Write-Step "3. Vérification locale des comptes de service"

try {
    $engineSid = (New-Object System.Security.Principal.NTAccount($SqlEngineAccount)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Ok "Compte résolvable : $SqlEngineAccount (SID $engineSid)"
} catch {
    Write-Fail "Compte non résolvable localement : $SqlEngineAccount"
    Write-Host "  → Vérifier que le compte existe dans AD (créé par 3.2.0 sur DC03)." -ForegroundColor Yellow
    exit 1
}

try {
    $agentSid = (New-Object System.Security.Principal.NTAccount($SqlAgentAccount)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Ok "Compte résolvable : $SqlAgentAccount (SID $agentSid)"
} catch {
    Write-Fail "Compte non résolvable localement : $SqlAgentAccount"
    Write-Host "  → Vérifier que le compte existe dans AD (créé par 3.2.0 sur DC03)." -ForegroundColor Yellow
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

# Calcul dynamique : 8 CPU max -  8 a la fin = Prends le nombre de CPU logiques de la machine, mais ne dépasse pas 8. 
$TempDbFileCount = [Math]::Min((Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors, 8)

$Args = @(
    "/Q",
    "/ACTION=Install",
    "/IACCEPTSQLSERVERLICENSETERMS",
    "/FEATURES=SQLENGINE",
    "/INSTANCENAME=MSSQLSERVER",
    "/SQLCOLLATION=SQL_Latin1_General_CP1_CI_AS",
    "/SQLSVCACCOUNT=$SqlEngineAccount",
    "/SQLSVCPASSWORD=$plainPwd",
    "/AGTSVCACCOUNT=$SqlAgentAccount",
    "/AGTSVCPASSWORD=$plainPwd",
    "/AGTSVCSTARTUPTYPE=Automatic",
    "/SQLSYSADMINACCOUNTS=`"$SysAdminAccount`"",
    "/INSTALLSQLDATADIR=S:\SQL\Data",
    "/SQLUSERDBLOGDIR=S:\SQL\Log",
    "/SQLBACKUPDIR=S:\SQL\Backup",
    "/SQLTEMPDBDIR=S:\SQL\TempDB",
    #"/SQLTEMPDBFILECOUNT=8",           # <<< : 8 fichiers TempDB (aligne sur 8 CPU logiques) - Adapter ---------------------
	"/SQLTEMPDBFILECOUNT=$TempDbFileCount", # avec cette la valeur est géré dynamiquement
	"/SQLTEMPDBFILESIZE=2048",        # 2 GB par fichier dès l'install
	"/SQLTEMPDBFILEGROWTH=512",       # 512 MB fixe
    "/TCPENABLED=1",
    "/NPENABLED=0"
)

Write-Ok "Nombre d'arguments : $($Args.Count)"
Write-Host "  Arguments (mot de passe masqué) :" -ForegroundColor Gray
$Args | ForEach-Object {
    if ($_ -match "PASSWORD") {
        Write-Host "    $($_ -replace '=.*', '=***')" -ForegroundColor Gray
    } else {
        Write-Host "    $_" -ForegroundColor Gray
    }
}

# ============================================================
# ÉTAPE 8 — Lancement de l'installation
# ============================================================
Write-Step "8. Lancement de l'installation"

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Installer SQL Server 2022 Developer")) {
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

# ============================================================
# ÉTAPE 9 — Nettoyage de la mémoire
# ============================================================
[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
Remove-Variable plainPwd, securePwd, key

Write-Host ""
Write-Host "Vérifier le résumé dans : %ProgramFiles%\Microsoft SQL Server\160\Setup Bootstrap\Log\" -ForegroundColor Cyan
Write-Host "Installation terminée." -ForegroundColor Green