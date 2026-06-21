<#
.SYNOPSIS
    Script de mappage reseau universel base sur les droits d'acces.
.DESCRIPTION
    - Attend la stabilisation du reseau (indispensable pour Windows 11/RDS).
    - Verifie la disponibilite du serveur avant de tenter les mappages.
    - Teste l'acces a chaque dossier : si l'utilisateur a le droit, le lecteur est monte.
.NOTES
    AUTHOR: Driss BENELKAID - optimedit.eu
    DATE: 08/06/2026
    VERSION: 1.1 (Production - Avec libellés de suivi Name)
#>
<#
Configuration GPO : Configuration utilisateur > Parametres Windows > Scripts > Ouverture de session.
Parametres : -ExecutionPolicy Bypass -WindowStyle Hidden
Note : Verifier que le fichier est "Debloque" dans les proprietes du fichier.
#>

# -----------------------------------------------------------------------------
# 1. PARAMETRES GENERIQUES - INFRASTRUCTURE CIBLE
# -----------------------------------------------------------------------------
$ServerFQDN  = "opt-fs02"
$UNCBase     = "\\$ServerFQDN"
$PathToTest  = "$UNCBase\OPT_Commun" # Dossier utilise pour valider la presence du serveur
$LogFile     = "$env:TEMP\LogonDrives_OptimedIt.log"
$NetworkObj  = New-Object -ComObject WScript.Network

# Liste des partages - NOMENCLATURE ET SERVICES OPT
$DrivesToTest = @(
    @{ Name = "Commun";       Letter = "K:"; Path = "$UNCBase\OPT_Commun" }
    @{ Name = "Direction";    Letter = "T:"; Path = "$UNCBase\OPT_Direction" }
    @{ Name = "Comptabilite"; Letter = "M:"; Path = "$UNCBase\OPT_Comptabilite" }
    @{ Name = "Paie";         Letter = "P:"; Path = "$UNCBase\OPT_Paie" }
    @{ Name = "RH";           Letter = "R:"; Path = "$UNCBase\OPT_RH" }
    @{ Name = "CE";           Letter = "C:"; Path = "$UNCBase\OPT_CE" }
    @{ Name = "IT";           Letter = "I:"; Path = "$UNCBase\OPT_IT" }
    @{ Name = "Production";   Letter = "W:"; Path = "$UNCBase\OPT_Production" }
    @{ Name = "Formation";    Letter = "F:"; Path = "$UNCBase\OPT_Formation" }
    @{ Name = "Achat";        Letter = "A:"; Path = "$UNCBase\OPT_Achat" }
    @{ Name = "Commercial";   Letter = "Q:"; Path = "$UNCBase\OPT_Commercial" }
    @{ Name = "Client";       Letter = "L:"; Path = "$UNCBase\OPT_Client" }
    @{ Name = "Juridique";    Letter = "J:"; Path = "$UNCBase\OPT_Juridique" }
    @{ Name = "Blog";         Letter = "B:"; Path = "$UNCBase\OPT_Blog" }
    
    # --- Services programmes pour integration future (Commentes pour la performance) ---
    @{ Name = "Dev";        Letter = "V:"; Path = "$UNCBase\OPT_projets_optimedit\Dev" }
    @{ Name = "Marketing";  Letter = "N:"; Path = "$UNCBase\OPT_Marketing" }
    @{ Name = "Logistique"; Letter = "O:"; Path = "$UNCBase\OPT_Logistique" }
    @{ Name = "RD";         Letter = "X:"; Path = "$UNCBase\OPT_RD" }
)

# -----------------------------------------------------------------------------
# 2. FONCTIONS DE SUPPORT
# -----------------------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $Stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$Stamp] $Message" | Out-File -FilePath $LogFile -Append
    Write-Host $Message
}

# -----------------------------------------------------------------------------
# 3. INITIALISATION ET ATTENTE RESEAU
# -----------------------------------------------------------------------------
# Nettoyage du vieux log pour repartir sur un fichier propre
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

Write-Log "--- DEBUT DE SESSION : $env:USERNAME ---"
Write-Log "Execution script netlogon : OptLogonScript.ps1"

# Pause initiale pour laisser Windows 11 stabiliser la pile reseau
Write-Log "Stabilisation reseau : Pause de 20 secondes..."
Start-Sleep -Seconds 20

# Boucle de verification de la disponibilite du service de fichiers
$RetryCount = 0
$MaxRetries = 10

while (!(Test-Path $PathToTest) -and ($RetryCount -lt $MaxRetries)) {
    Write-Log "ATTENTE : Serveur ou partage test invisible (Tentative $($RetryCount + 1)/$MaxRetries)..."
    Start-Sleep -Seconds 5
    $RetryCount++
}

# Arret si le reseau est definitivement indisponible
if (!(Test-Path $PathToTest)) {
    Write-Log "FATAL : Reseau ou serveur injoignable apres $MaxRetries tentatives. Arret."
    # Ouverture du log meme en cas d'echec pour diagnostic
    notepad.exe $LogFile
    exit
}

# -----------------------------------------------------------------------------
# 4. NETTOYAGE ET MAPPAGE BASE SUR LES DROITS REELS
# -----------------------------------------------------------------------------

# Nettoyage global initial
Write-Log "Nettoyage des anciennes connexions reseau..."
net use * /delete /y >$null 2>&1
Start-Sleep -Seconds 2

foreach ($Drive in $DrivesToTest) {
    # On teste si l'utilisateur a reellement acces au dossier
    if (Test-Path $Drive.Path) {
        try {
            # Nettoyage specifique de la lettre avant montage pour eviter les doublons
            $letter = $Drive.Letter
            net use $letter /delete /y >$null 2>&1
            
            # Mappage avec persistance
            $NetworkObj.MapNetworkDrive($Drive.Letter, $Drive.Path, $true)
            Write-Log "SUCCES : Lecteur $($Drive.Letter) monte pour le service [$($Drive.Name)] sur $($Drive.Path)"
        } catch {
            Write-Log "ERREUR : $($Drive.Letter) ($($_.Exception.Message))"
        }
    } else {
        Write-Log "INFO : Acces non autorise ou dossier inexistant pour le service [$($Drive.Name)]"
    }
}

Write-Log "--- FIN DU SCRIPT POUR $env:USERNAME ---"

# -----------------------------------------------------------------------------
# 5. OUVERTURE DU LOG POUR VERIFICATION (A commenter avant mise en GPO)
# -----------------------------------------------------------------------------
notepad.exe $LogFile