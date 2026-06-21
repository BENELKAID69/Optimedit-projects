<#
.SYNOPSIS
    Nom du script : 03.ConfigureWinRM-FQDN-CA-Optimedit.ps1 (Version V5.3 - Production & Back-up)
    Configuration locale du Listener WinRM HTTPS (5986) basée sur l'OID de modèle immuable.

.DESCRIPTION
    Ce script est conçu pour être stocké dans le dossier \\optimedit.eu\NETLOGON\ et exécuté 
    automatiquement sur les serveurs cibles via une Tâche Planifiée déployée par GPO.
    
    [NOTE DE SÉCURITÉ & ARCHITECTURE - DOCUMENTATION VERBOSE]
    Ce script STRICT V5 s'appuie obligatoirement sur la présence préalable d'une infrastructure ADCS fonctionnelle :
    
    * ÉTAPE 1 : L'enrôlement automatique immédiat (Le comportement réel)
      Dès qu'un nouveau serveur (ex: OPT-IIS-01) intègre le domaine, il applique les stratégies de groupe. 
      Le composant natif Windows 'CertEnroll' intercepte la directive d'auto-enrôlement. Si la machine appartient 
      au groupe autorisé (ex: Ordinateurs du domaine), Windows génère IMMÉDIATEMENT le certificat auprès de la CA.
      Le certificat est donc présent en magasin avant même l'exécution du moindre script.
    
    * ÉTAPE 2 : L'absence de configuration WinRM (L'explication de la Tâche Planifiée)
      Bien que le certificat soit présent dès le premier démarrage, l'écouteur WinRM (Listener 5986) ne sera pas 
      configuré tant que la Tâche Planifiée (souvent hebdomadaire, ex: le lundi) n'aura pas appelé ce présent script.
    
    ATTENTION : Cette version V5 NE DOIT PAS être utilisée si la GPO d'auto-enrôlement n'est pas active, 
    car elle ne possède aucun mécanisme interne de génération de certificat et lèvera une erreur critique.

.AUTEUR
    Optimedit / Driss BENELKAID
#>

# --- Variables de référence -----------------------------
$CurrentFQDN = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()
$TargetOID   = "1.3.6.1.4.1.311.21.8.7103102.15251863.2049408.3177376.8187667.136.12355323.6820193"

# --- Logging Local --------------------------------------
$LogLocalDir  = "C:\temp"
$LogLocalFile = Join-Path $LogLocalDir "WinRM_Config_History.log"
$Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if (!(Test-Path $LogLocalDir)) { 
    New-Item -Path $LogLocalDir -ItemType Directory -Force | Out-Null 
}

# --- Initialisation WinRM de base ---
Set-Service -Name "WinRM" -StartupType Automatic
Start-Service -Name "WinRM" -ErrorAction SilentlyContinue

# --- Recherche du certificat par OID de modèle ---
Write-Host "Analyse du magasin par OID de modèle..." -ForegroundColor Cyan

$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
    $isMatch = $false
    # L'extension "Template" possède l'OID standard 1.3.6.1.4.1.311.21.7
    $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
    
    if ($null -ne $templateExt) {
        # Match de l'OID brut du modèle pour éviter les problèmes de langue/résolution
        if ($templateExt.Format(0) -match $TargetOID) {
            $isMatch = $true
        }
    }
    return $isMatch
} | Sort-Object NotBefore -Descending | Select-Object -First 1

# --- Validation de la présence du certificat ---
if ($null -eq $cert) {
    Write-Error "CRITIQUE : Aucun certificat correspondant à l'OID $TargetOID trouvé !"
    Write-Error "Rappel : Le script V5 requiert que l'étape 1 (Auto-enrôlement natif Windows) ait déjà déposé le certificat."
    "[$Timestamp] ERROR: Échec de configuration WinRM - Certificat introuvable pour l'OID $TargetOID" | Out-File -FilePath $LogLocalFile -Append -Encoding UTF8
    exit 1
}

$CurrentThumbprint = $cert.Thumbprint
Write-Host "Certificat conforme identifié : $CurrentFQDN ($CurrentThumbprint)" -ForegroundColor Green

# --- Nettoyage et Création du Listener WinRM HTTPS ---
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -like "TRANSPORT=HTTPS" } | ForEach-Object {
    Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue
}

$valueset = @{ Hostname = $CurrentFQDN; CertificateThumbprint = $CurrentThumbprint }
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Transport="HTTPS"; Address="*"} -ValueSet $valueset | Out-Null

# --- Configuration du Pare-feu Windows ---
if (!(Get-NetFirewallRule -Name "AllowWinRMHTTPS" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow WinRM HTTPS" -Name "AllowWinRMHTTPS" -Profile Any -LocalPort 5986 -Protocol TCP -Action Allow -Direction Inbound | Out-Null
}

# --- Redémarrage asynchrone du service WinRM ---
Start-Job -ScriptBlock { 
    Start-Sleep -Seconds 2
    Restart-Service winrm -Force 
} | Out-Null

# --- Historisation du statut (Append) ---
$LogMessage = "[$Timestamp] SUCCESS: WinRM configuré avec le certificat $CurrentThumbprint (OID: $TargetOID)"
$LogMessage | Out-File -FilePath $LogLocalFile -Append -Encoding UTF8

Write-Host "Log local mis à jour : $LogLocalFile" -ForegroundColor Gray
Write-Host "Configuration terminée. Le Listener utilise désormais l'OID immuable." -ForegroundColor Green

# --- OUTILS DE VÉRIFICATION AD (Pour mémoire d'administration) ----------------------------------------------------
# Get-ADObject -SearchBase "CN=Certificate Templates,CN=Public Key Services,CN=Services,$((Get-ADRootDSE).configurationNamingContext)" -Filter * -Properties displayName, msPKI-Cert-Template-OID | Select-Object displayName, msPKI-Cert-Template-OID