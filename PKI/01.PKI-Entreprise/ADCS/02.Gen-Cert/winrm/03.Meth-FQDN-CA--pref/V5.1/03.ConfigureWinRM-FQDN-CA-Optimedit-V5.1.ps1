<#
.SYNOPSIS
    Nom du script : 03.ConfigureWinRM-FQDN-CA-Optimedit-V5.1.ps1
    Rôle : Audit de l'auto-enrôlement et montage du Listener sécurisé WinRM HTTPS (5986).

.DESCRIPTION
    Ce script est poussé et s'exécute localement sur le système d'exploitation de la machine cible.
    Son cycle d'exécution applique le mécanisme d'ingénierie suivant :
    1. Activation automatique du service WinRM local et activation de la stack PSRemoting.
    2. Modification de la clé UAC 'LocalAccountTokenFilterPolicy' indispensable pour qu'Ansible puisse administrer en root distant.
    3. Inspection de la ruche de registre système pour valider si la GPO d'auto-enrôlement machine est active.
    4. Scan minutieux du magasin de certificats 'Personnel' local basé sur l'OID immuable du modèle.
    5. Si absent : Diagnostic précis (GPO active mais non appliquée, ou GPO totalement absente) et sortie propre.
    6. Si présent : Purge absolue des anciens Listeners HTTPS obsolètes.
    7. Création de l'instance d'écoute WSMan HTTPS liée au FQDN de l'hôte et au Thumbprint du certificat valide.
    8. Ouverture et sécurisation du port 5986 dans le Pare-feu Windows.
    9. Redémarrage programmé et asynchrone du service WinRM pour valider les liaisons.

.PREREQUIS EXERÇÉS PAR LA GPO
    - GPO d'Auto-enrôlement : Doit être active et configurée à la valeur d'état de politique de renouvellement '7'.
    - Modèle ADCS : Le modèle de certificat ciblé doit donner le droit "Auto-enroll" aux ordinateurs du domaine.
    - Firewall local : Le script va forcer l'ouverture du port TCP Inbound 5986.
#>

# --- ÉTAPE 1 : INITIALISATION DE L'ENVIRONNEMENT ET DES RÉFÉRENCES CIBLES ---
# Construction dynamique du FQDN en lettres minuscules pour correspondre à la casse de la CA
$CurrentFQDN  = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()

# Identifiant OID unique et immuable généré par votre Active Directory Certificate Services pour votre modèle
$TargetOID    = "1.3.6.1.4.1.311.21.8.14486171.8174028.1852035.15823050.2457292.12.15333706.10047583"
$LogLocalFile = "C:\temp\WinRM_Config_History.log"
$Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# --- ÉTAPE 2 : INITIALISATION DES COMPOSANTS LOGICIELS WINRM ---
Write-Host "Vérification et démarrage du service système WinRM..." -ForegroundColor Cyan
Set-Service -Name "WinRM" -StartupType Automatic
Start-Service -Name "WinRM" -ErrorAction SilentlyContinue

# Initialisation de base de la pile WS-Management et levée des blocages de profils réseaux
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null

# --- ÉTAPE 3 : DURCISSEMENT DE L'UAC POUR LE COMPTE DE SERVICE ANSIBLE ---
# Cette modification de registre supprime la restriction d'accès réseau UAC pour les comptes administrateurs locaux non-natifs.
# Sans cette clé, Ansible subit un rejet systématique d'accès sur le port 5986.
Write-Host "Configuration de la clé de registre LocalAccountTokenFilterPolicy (UAC Fix)..." -ForegroundColor Cyan
$tokenPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-ItemProperty -Path $tokenPath -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord | Out-Null

# --- ÉTAPE 4 : AUDIT POLICIER DE L'AUTO-ENRÔLEMENT REÇU PAR GPO ---
# Recherche de la clé injectée par les stratégies de groupe Microsoft concernant le chiffrement
$AePath = "HKLM:\SOFTWARE\Policies\Microsoft\Cryptographic\AutoEnrollment"
$GpoActive = $false

if (Test-Path $AePath) {
    # Lecture de la valeur de configuration de l'auto-enrôlement (La valeur 7 indique l'activation complète)
    $PolicyVal = Get-ItemPropertyValue -Path $AePath -Name "Policy" -ErrorAction SilentlyContinue
    if ($PolicyVal -eq 7) { 
        $GpoActive = $true 
    }
}

# --- ÉTAPE 5 : SCAN DES EXTENSIONS DU MAGASIN DE CERTIFICATS MACHINE ---
function Get-TargetCertificate {
    # Analyse de la ruche locale 'Mon magasin personnel' de l'ordinateur
    Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object {
        $isMatch = $false
        # Extraction de l'extension d'information du modèle de certificat de l'ADCS (OID 1.3.6.1.4.1.311.21.7)
        $templateExt = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
        if ($null -ne $templateExt) {
            # Comparaison du format brut textuel de l'extension avec l'OID de référence cible
            if ($templateExt.Format(0) -match $TargetOID) { $isMatch = $true }
        }
        return $isMatch
    } | Sort-Object NotBefore -Descending | Select-Object -First 1 # Sélection du certificat conforme le plus récent
}

$cert = Get-TargetCertificate

# --- ÉTAPE 6 : BLOCAGE INTELLIGENT ET DIAGNOSTIC SUR ERREUR ---
if ($null -eq $cert) {
    Write-Host "`n[ALERTE] Aucun certificat valide trouvé pour l'OID du modèle." -ForegroundColor Yellow
    
    if ($GpoActive) {
        # Scénario : La GPO dit au serveur de s'enrôler, mais l'OS n'a pas encore traité l'ordre
        Write-Host "[CONSEIL] La GPO d'auto-enrôlement est pourtant ACTIVÉE sur ce serveur." -ForegroundColor Green
        Write-Host "[ACTION] Le certificat n'a pas encore été généré. Exécutez 'gpupdate /force' sur ce serveur pour déclencher l'ADCS." -ForegroundColor Cyan
    } else {
        # Scénario : Le serveur n'est pas ciblé par la GPO d'auto-enrôlement dans l'AD
        Write-Host "[CONSEIL] La GPO d'auto-enrôlement machine semble INACTIVE ou non appliquée sur ce serveur." -ForegroundColor Red
        Write-Host "[ACTION] Liez la GPO d'auto-enrôlement à l'Unité Organisationnelle (OU) contenant ce serveur, puis faites un 'gpupdate /force'." -ForegroundColor Cyan
    }
    
    # Inscription de l'interruption dans le log local
    "[$Timestamp] ERROR: Configuration interrompue. Certificat absent du magasin local." | Out-File -FilePath $LogLocalFile -Append -Encoding UTF8
    exit 1
}

# --- ÉTAPE 7 : NETTOYAGE ET CRÉATION DE L'ÉCOUTEUR WINRM HTTPS ---
$CurrentThumbprint = $cert.Thumbprint
Write-Host "Certificat conforme identifié : $CurrentFQDN ($CurrentThumbprint)" -ForegroundColor Green

# Purge obligatoire des anciens écouteurs HTTPS configurés sur le port standard
Write-Host "Nettoyage des anciens écouteurs WSMan HTTPS..." -ForegroundColor Yellow
Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -like "TRANSPORT=HTTPS" } | ForEach-Object {
    Remove-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Address="*";Transport="HTTPS"} -ErrorAction SilentlyContinue
}

# Instanciation de l'instance d'écoute WSMan HTTPS officielle liée au certificat valide
Write-Host "Création du nouveau listener WinRM HTTPS (5986) lié au FQDN..." -ForegroundColor Green
$valueset = @{ Hostname = $CurrentFQDN; CertificateThumbprint = $CurrentThumbprint }
New-WSManInstance -ResourceURI 'winrm/config/Listener' -SelectorSet @{Transport="HTTPS"; Address="*"} -ValueSet $valueset | Out-Null

# --- ÉTAPE 8 : SÉCURISATION DU PARE-FEU WINDOWS (PORT 5986) ---
Write-Host "Vérification et ouverture de la règle de pare-feu Port 5986..." -ForegroundColor Cyan
if (!(Get-NetFirewallRule -Name "AllowWinRMHTTPS" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow WinRM HTTPS" -Name "AllowWinRMHTTPS" -Profile Any -LocalPort 5986 -Protocol TCP -Action Allow -Direction Inbound | Out-Null
}

# --- ÉTAPE 9 : REDÉMARRAGE EN ARRIÈRE-PLAN DU SERVICE WINRM ---
# Le redémarrage est délégué à un Job asynchrone avec délai pour éviter de couper la session Invoke-Command en cours
Start-Job -ScriptBlock { 
    Start-Sleep -Seconds 2
    Restart-Service winrm -Force 
} | Out-Null

# --- ÉTAPE 10 : TRAÇABILITÉ HISTORIQUE ---
"[$Timestamp] SUCCESS: WinRM [V5.1] configuré avec succès pour $CurrentFQDN avec le certificat $CurrentThumbprint" | Out-File -FilePath $LogLocalFile -Append -Encoding UTF8
Write-Host "Configuration WinRM HTTPS complétée avec succès pour $CurrentFQDN." -ForegroundColor Green