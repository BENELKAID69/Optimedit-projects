<#
.SYNOPSIS
    Nom du script : 03.InstallWinRM-FQDN-CA-Optimedit.ps1 (Version V5.1-Deployer-Enriched)
    Rôle : Centraliser, orchestrer et pousser la configuration WinRM HTTPS sur les parcs IIS/Citrix.

.DESCRIPTION
    Ce script s'exécute localement depuis votre contrôleur de domaine (DC) ou votre serveur d'administration.
    Il exécute le mécanisme de déploiement suivant :
    1. Vérification / Création centralisée du compte de service Active Directory 'admin_ansible'.
    2. Test de connectivité initiale (Ping) vers chaque serveur de la liste.
    3. Connexion SMB pour créer le répertoire local 'C:\temp' sur la machine distante.
    4. Copie du script esclave (Configure) depuis le partage local directement vers 'C:\temp' (Bypass le Double-Hop).
    5. Injection du compte de service dans le groupe des 'Administrateurs' locaux de la cible.
    6. Déclenchement à distance de l'exécution du script local esclave via Invoke-Command.
    7. Centralisation et affichage du statut de conformité final de toutes les cibles.

.PREREQUIS & CONFIGURATION REQUISE
    - Compte d'exécution : Administrateur du domaine (OPTIMEDIT.EU).
    - Flux Réseau Cibles (Inbound) : 
        * ICMPv4 (Ping) : Requis pour la validation de présence d'hôte.
        * SMB (Port 445 TCP) : Indispensable pour la copie administrative du fichier (C$).
        * WinRM HTTP (Port 5985) : Utilisé temporairement par Invoke-Command pour exécuter la bascule.
    - Dépendances AD : Module ActiveDirectory chargé sur la console d'exécution.
.COMMANDES
	- forcer l'Auto-Enrôlement à distance:
		Get-ScheduledTask -TaskName "AutomaticCertificateEnrollment" -TaskPath "\Microsoft\Windows\CertificateServicesClient\" | Start-ScheduledTask
#>

# --- ÉTAPE 1 : INITIALISATION DES PARAMÈTRES ET IDENTIFIANTS COMPTE ANSIBLE ---
$UserName    = "admin_ansible"
$DomainName  = "OPTIMEDIT.EU"
$Password     = ConvertTo-SecureString "Dr/*-101977" -AsPlainText -Force

# Déclaration explicite du parc de serveurs cibles à configurer
$Servers     = @("OPT-IIS-02.optimedit.eu", "OPT-FS02.optimedit.eu", "OPT-IIS-03.optimedit.eu")

# Résolution LOCALE du script de configuration (Ce script doit résider dans votre partage NETLOGON)
$SourcePath  = "\\optimedit.eu\NETLOGON\03.ConfigureWinRM-FQDN-CA-Optimedit-V5.1.ps1"

# Garde-fou : Validation stricte de l'accès au fichier source avant d'engager les connexions réseau
if (-not (Test-Path -Path $SourcePath)) {
    Write-Host "[STOP] Erreur critique : Le fichier esclave $SourcePath est introuvable." -ForegroundColor Red
    return
}
# Extraction du nom de fichier isolé (ex: 03.ConfigureWinRM-FQDN-CA-Optimedit-V5.1.ps1)
$LeafName = Split-Path $SourcePath -Leaf

# --- ÉTAPE 2 : SÉCURISATION ET PROVISIONNING DU COMPTE DE SERVICE DANS L'AD ---
Write-Host "--- Vérification du compte AD : $UserName ---" -ForegroundColor Cyan
if (-not (Get-ADUser -Filter "SamAccountName -eq '$UserName'")) {
    Write-Host "Compte introuvable. Création du compte de service de l'infra Ansible..." -ForegroundColor Yellow
    New-ADUser -Name $UserName -SamAccountName $UserName -AccountPassword $Password -Enabled $true -PasswordNeverExpires $true -DisplayName "Ansible Root Account"
    
    # Durcissement de la sécurité Kerberos : Chiffrement AES256 forcé et autorisation de délégation standard
    Set-ADUser -Identity $UserName -KerberosEncryptionType AES256 -AccountNotDelegated $false | Out-Null
    Write-Host "[OK] Compte créé et durci en AES256." -ForegroundColor Green
} else {
    Write-Host "Le compte $UserName existe déjà et est prêt." -ForegroundColor Yellow
}

# --- ÉTAPE 3 : CYCLE DE DÉPLOIEMENT SUR LES MACHINES DISTANTES ---
Write-Host "`n--- Configuration des serveurs cibles ---" -ForegroundColor Cyan

foreach ($Server in $Servers) {
    Write-Host "Traitement de $Server..." -ForegroundColor White
    
    # Vérification réseau par ICMP (Ping)
    if (Test-Connection -ComputerName $Server -Count 1 -Quiet) {
        
        # Validation / Création du dossier d'atterrissage local C:\temp sur la cible
        Invoke-Command -ComputerName $Server -ScriptBlock {
            if (-not (Test-Path "C:\temp")) { 
                New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null 
            }
        }

        # Transfert du script de configuration via canal SMB direct (Évite le problème de Double-Hop)
        try {
            Copy-Item -Path $SourcePath -Destination "\\$Server\C$\temp\$LeafName" -ErrorAction Stop
            Write-Host "  [OK] Script de configuration copié via SMB avec succès." -ForegroundColor Green
        } catch {
            Write-Host "  [ERREUR] Échec du transfert SMB vers $Server : $($_.Exception.Message)" -ForegroundColor Red
            continue # Passage au serveur suivant si la copie échoue
        }
        
        # Connexion à distance via Invoke-Command (Saut 1) pour exécuter la logique locale
        Invoke-Command -ComputerName $Server -ScriptBlock {
            param($UserName, $DomainName, $LeafName)
            
            # Établissement de l'identité complète (ex: OPTIMEDIT.EU\admin_ansible)
            $FullUserName = "$DomainName\$UserName"
            try {
                # Élévation du compte Ansible au rang d'Administrateur Local du serveur cible
                Add-LocalGroupMember -Group "Administrateurs" -Member $FullUserName -ErrorAction Stop | Out-Null
                Write-Host "  [OK] $FullUserName ajouté au groupe local Administrateurs." -ForegroundColor Green
            } catch {
                # Message informatif si l'identité est déjà présente (comportement normal)
                Write-Host "  [INFO] $FullUserName est déjà présent dans le groupe." -ForegroundColor Yellow
            }
            
            # Reconstruction du chemin d'accès absolu en contexte local de la cible
            $RemoteScript = "C:\temp\$LeafName"
            if (Test-Path $RemoteScript) {
                Write-Host "  [EXEC] Déclenchement de la configuration locale sur la cible..." -ForegroundColor Cyan
                # Exécution par l'opérateur de sous-expression '&' du script localisé
                & $RemoteScript
            }
        } -ArgumentList $UserName, $DomainName, $LeafName

    } else {
        Write-Host "  [ERREUR] Le serveur $Server ne répond pas au Ping. Configuration annulée." -ForegroundColor Red
    }
}

# --- ÉTAPE 4 : COLLECTE CENTRALISÉE ET CONSOLIDATION DES LOGS DISTANTS ---
Write-Host "`n--- Récapitulatif des Logs de configuration ---" -ForegroundColor Cyan
Invoke-Command -ComputerName $Servers -ScriptBlock {
    $LogPath = "C:\temp\WinRM_Config_History.log"
    # Lecture exclusive de la dernière ligne du fichier log historique local
    $LogContent = if (Test-Path $LogPath) { Get-Content $LogPath -Tail 1 } else { "Fichier introuvable" }
    
    # Génération d'un objet formaté personnalisé pour la console d'administration
    [PSCustomObject]@{
        Serveur = $env:COMPUTERNAME
        Statut  = $LogContent
    }
} | Format-Table -AutoSize


<#
# 4. Affichage du statut final basé sur les logs distants
Write-Host "`n--- Récapitulatif des Logs de configuration ---" -ForegroundColor Cyan
Invoke-Command -ComputerName $Servers -ScriptBlock {
    $LogPath = "C:\temp\WinRM_Config_History.log"
    $LogContent = "Fichier de log introuvable"
    
    if (Test-Path $LogPath) {
        $LogContent = Get-Content $LogPath -Tail 1
    }

    [PSCustomObject]@{
        Serveur = $env:COMPUTERNAME
        Statut  = $LogContent
    }
} | Format-Table -AutoSize


# ************************************************************  tape de vérification  ********************************************************

Write-Host "`n=== VERIFICATION REELLE DES ECOUTEURS WINRM HTTPS (5986) ===" -ForegroundColor Yellow
# Même commande, mais triée proprement pour tes archives
Invoke-Command -ComputerName $Servers -ScriptBlock {
    Get-WSManInstance -ResourceURI "winrm/config/listener" -Enumerate | 
    Where-Object { $_.Transport -eq "HTTPS" } | ForEach-Object {
        [PSCustomObject]@{
            Service    = "WinRM HTTPS"
            Port       = $_.Port
            Transport  = $_.Transport
            Actif      = $_.Enabled
            Hostname   = $_.Hostname
            Cert_Thumb = $_.CertificateThumbprint
        }
    }
} | Select-Object @{Name="Serveur"; Expression={$_.PSComputerName}}, Service, Port, Transport, Actif, Hostname, Cert_Thumb | 
  Sort-Object Serveur | 
  Format-Table -AutoSize
  
#>