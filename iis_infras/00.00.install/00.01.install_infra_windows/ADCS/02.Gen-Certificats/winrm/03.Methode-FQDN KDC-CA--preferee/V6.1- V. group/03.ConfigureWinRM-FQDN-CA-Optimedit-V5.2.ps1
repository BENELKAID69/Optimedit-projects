<#
.SYNOPSIS
    Nom du script : 03.ConfigureWinRM-FQDN-CA-Optimedit-V5.2.ps1
    Rôle : Audit GPO, déclenchement de l'auto-enrôlement et montage du Listener WinRM HTTPS (5986).

.DESCRIPTION
    Exécuté localement sur l'OS cible, ce script applique la cinématique d'ingénierie suivante :
    1. Initialisation automatique de la stack WinRM et PSRemoting locale.
    2. Ajustement de la clé de registre LocalAccountTokenFilterPolicy pour lever les restrictions UAC d'Ansible.
    3. Analyse fine de la ruche de registre pour vérifier l'activation de la GPO d'auto-enrôlement.
    4. Si le certificat cible par OID est manquant, le script force l'exécution de la tâche planifiée d'enrôlement.
    5. Recherche du certificat généré, suppression des anciens listeners, et montage du listener HTTPS sécurisé.
    6. Configuration automatique de la règle de Pare-feu entrante pour le port 5986.

.PREREQUIS TECHNIQUES
    - GPO Auto-enrôlement : Activée (valeur de clé de registre égale à 7).
    - Autorisations ADCS : Les machines du domaine doivent détenir le droit "Inscrire" et "Auto-inscrire" sur le modèle.
    - Pare-feu : Port TCP Inbound 5986 sera configuré et ouvert par ce script.
#>


# --- ÉTAPE 1 : INITIALISATION DE L'ENVIRONNEMENT ET DES RÉFÉRENCES ---
$CurrentFQDN  = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()
# Identifiant OID unique de votre modèle de certificat ADCS
$TargetOID    = "1.3.6.1.4.1.311.21.8.14486171.8174028.1852035.15823050.2457292.12.15333706.10047583"
$LogLocalFile = "C:\temp\WinRM_Config_History.log"
$Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Activation et démarrage du service local WinRM
Set-Service -Name "WinRM" -StartupType Automatic
Start-Service -Name "WinRM" -ErrorAction SilentlyContinue
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

# Configuration de la clé UAC pour permettre l'accès root réseau à Ansible
$tokenPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $tokenPath -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord | Out-Null

# --- ÉTAPE 2 : CONTRÔLE DE L'ÉTAT DE LA GPO D'AUTO-ENRÔLEMENT ---
$AePath = "HKLM:\SOFTWARE\Policies\Microsoft\Cryptographic\AutoEnrollment"
$GpoActive = $false

if (Test-Path $AePath) {
    $PolicyVal = Get-ItemPropertyValue -Path $AePath -Name "Policy" -ErrorAction SilentlyContinue
    if ($PolicyVal -eq 7) { $GpoActive = $true }
}

# --- ÉTAPE 3 : FONCTION DE DETECTION DU CERTIFICAT PAR OID ---
function Get-TargetCertificate {
    Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
        $isMatch = $false
        $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
        if ($null -ne $templateExt) {
            if ($templateExt.Format(0) -match $TargetOID) { $isMatch = $true }
        }
        return $isMatch
    } | Sort-Object NotBefore -Descending | Select-Object -First 1
}

# Premier scan du magasin de certificats personnel de la machine
$cert = Get-TargetCertificate

# --- ÉTAPE 4 : DÉCLENCHEMENT SÉCURISÉ DE L'ENRÔLEMENT SI ABSENT ---
if ($null -eq $cert) {
    Write-Host "[INFO] Certificat OID introuvable dans le magasin local. Analyse de la politique..." -ForegroundColor Yellow
    
    if ($GpoActive) {
        Write-Host "[EXEC] GPO présente. Forçage de la tâche planifiée d'auto-enrôlement Windows..." -ForegroundColor Cyan
        # Appel direct au moteur de tâches planifiées de l'OS local pour contourner les limitations de gpupdate
        Get-ScheduledTask -TaskName "AutomaticCertificateEnrollment" -TaskPath "\Microsoft\Windows\CertificateServicesClient\" | Start-ScheduledTask
        
        # Pause de synchronisation pour laisser le temps à l'OS d'échanger avec la CA
        Start-Sleep -Seconds 5
        
        # Second scan de validation après déclenchement de la tâche planifiée
        $cert = Get-TargetCertificate
    }
}

# --- ÉTAPE 5 : ANOMALIE ET DISPONSABILITÉ DU CERTIFICAT ---
if ($null -eq $cert) {
    Write-Host "`n[ALERTE REJET] Impossible de trouver ou de générer le certificat." -ForegroundColor Red
    if ($GpoActive) {
        Write-Host "[DIAGNOSTIC] La GPO est active, mais la tâche planifiée a échoué. Vérifiez les droits de sécurité du modèle sur votre CA ADCS." -ForegroundColor Yellow
    } else {
        Write-Host "[DIAGNOSTIC] La GPO d'auto-enrôlement n'est pas appliquée sur cette machine. Liez-la dans l'AD." -ForegroundColor Red
    }
    "[$Timestamp] ERROR: Configuration interrompue. Certificat absent après forçage de l'auto-enrôlement." | Out-File -FilePath $LogLocalFile -Append -Encoding UTF8
    exit 1
}

# --- ÉTAPE 6 : CONFIGURATION DU LISTENER ET DU PARE-FEU WINDOWS ---
$CurrentThumbprint = $cert.Thumbprint
Write-Host "Certificat conforme identifié : $CurrentFQDN ($CurrentThumbprint)" -ForegroundColor Green

# Suppression complète des anciens écouteurs HTTPS obsolètes
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -like "TRANSPORT=HTTPS" } | ForEach-Object {
    Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue
}

# Instanciation de l'écouteur officiel lié au FQDN de l'hôte et au certificat valide
$valueset = @{ Hostname = $CurrentFQDN; CertificateThumbprint = $CurrentThumbprint }
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Transport="HTTPS"; Address="*"} -ValueSet $valueset | Out-Null

# Configuration de la règle de pare-feu entrante (Port TCP 5986)
if (!(Get-NetFirewallRule -Name "AllowWinRMHTTPS" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow WinRM HTTPS" -Name "AllowWinRMHTTPS" -Profile Any -LocalPort 5986 -Protocol TCP -Action Allow -Direction Inbound | Out-Null
}

# Redémarrage asynchrone du service WinRM local pour sceller les liaisons
Start-Job -ScriptBlock { Start-Sleep -Seconds 2; Restart-Service winrm -Force } | Out-Null

# Inscription du succès de la configuration dans les logs historiques locaux
"[$Timestamp] SUCCESS: WinRM [V5.2] configuré avec succès pour $CurrentFQDN avec le certificat $CurrentThumbprint" | Out-File -FilePath $LogLocalFile -Append -Encoding UTF8
Write-Host "Configuration WinRM HTTPS complétée avec succès." -ForegroundColor Green