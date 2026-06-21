<#
.SYNOPSIS
    Nom du script : 03.InstallWinRM-FQDN-CA-Optimedit.ps1 (Version V5.2-Deployer)
    Rôle : Centraliser, orchestrer et pousser la configuration WinRM HTTPS sur le parc.

.DESCRIPTION
    Ce script s'exécute localement depuis votre console d'administration.
    Mécanisme de déploiement :
    1. Validation / Création du compte Active Directory 'admin_ansible' sécurisé en AES256.
    2. Test de connectivité ICMP (Ping) avant d'engager les connexions.
    3. Montage du dossier local 'C:\temp' et poussée du script esclave via canal SMB direct.
    4. Élévation du compte Ansible au rang d'Administrateur local de la machine cible.
    5. Déclenchement à distance de l'exécution du script local esclave via Invoke-Command.
    6. Consolidation finale des logs historiques de configuration et validation des écouteurs.

.PREREQUIS & MATRICE DE FLUX
    - Compte d'exécution : Droits 'Domain Admin' requis sur le domaine OPTIMEDIT.EU.
    - Flux réseau requis vers les serveurs cibles :
        * ICMPv4 (Ping) : Diagnostiquer la présence en ligne de la machine.
        * SMB (Port 445 TCP) : Pousser le script de configuration dans le partage administratif C$.
        * WinRM HTTP (Port 5985 TCP) : Canal initial temporaire requis pour Invoke-Command.
    - GPO : L'auto-enrôlement des certificats doit être configuré dans votre infrastructure Active Directory.
#>

# --- ÉTAPE 1 : PARAMÉTRAGE GLOBAUX ET COMPTE DE SERVICE ANSIBLE ---
$UserName    = "admin_ansible"
$DomainName  = "OPTIMEDIT.EU"
$Password     = ConvertTo-SecureString "Dr/*-101977" -AsPlainText -Force

# Déclaration de votre parc complet de serveurs de production
$Servers     = @("OPT-IIS-01.optimedit.eu", "OPT-IIS-02.optimedit.eu", "OPT-IIS-03.optimedit.eu", "OPT-IIS-04.optimedit.eu", "OPT-FS02.optimedit.eu", "OPT-DC02.optimedit.eu")

# Résolution locale du fichier source esclave situé dans votre partage NETLOGON
$SourcePath  = "\\optimedit.eu\NETLOGON\03.ConfigureWinRM-FQDN-CA-Optimedit-V5.2.ps1"

# Sécurité : Validation de la présence du script esclave avant d'initier le traitement
if (-not (Test-Path -Path $SourcePath)) {
    Write-Host "[STOP] Erreur critique : Le fichier source $SourcePath est introuvable." -ForegroundColor Red
    return
}
$LeafName = Split-Path $SourcePath -Leaf

# --- ÉTAPE 2 : PROVISIONNING DU COMPTE DE SERVICE DANS L'ACTIVE DIRECTORY ---
Write-Host "--- Vérification du compte AD : $UserName ---" -ForegroundColor Cyan
if (-not (Get-ADUser -Filter "SamAccountName -eq '$UserName'")) {
    Write-Host "Compte introuvable. Provisionning du compte de service Ansible..." -ForegroundColor Yellow
    New-ADUser -Name $UserName -SamAccountName $UserName -AccountPassword $Password -Enabled $true -PasswordNeverExpires $true -DisplayName "Ansible Root Account"
    
    # Durcissement de la sécurité Kerberos : Chiffrement AES256 obligatoire
    Set-ADUser -Identity $UserName -KerberosEncryptionType AES256 -AccountNotDelegated $false | Out-Null
    Write-Host "[OK] Compte de service créé et durci en chiffrement AES256." -ForegroundColor Green
} else {
    Write-Host "Le compte $UserName existe déjà dans l'Active Directory et est opérationnel." -ForegroundColor Yellow
}

# --- ÉTAPE 3 : CYCLE ORCHESTRÉ DE DÉPLOIEMENT ---
Write-Host "`n--- Configuration des serveurs cibles ---" -ForegroundColor Cyan

foreach ($Server in $Servers) {
    Write-Host "Traitement de $Server..." -ForegroundColor White
    
    # Validation de l'accessibilité réseau de l'hôte via Ping
    if (Test-Connection -ComputerName $Server -Count 1 -Quiet) {
        
        # Vérification et provisionning du dossier C:\temp à distance sur la cible
        Invoke-Command -ComputerName $Server -ScriptBlock {
            if (-not (Test-Path "C:\temp")) { 
                New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null 
            }
        }

        # Copie locale du script vers la cible via SMB (Évite le Double-Hop de fichier)
        try {
            Copy-Item -Path $SourcePath -Destination "\\$Server\C$\temp\$LeafName" -ErrorAction Stop
            Write-Host "  [OK] Script de configuration copié via SMB avec succès." -ForegroundColor Green
        } catch {
            Write-Host "  [ERREUR] Impossible de copier le fichier vers $Server : $($_.Exception.Message)" -ForegroundColor Red
            continue 
        }
        
        # Exécution à distance de la logique de configuration locale (Saut 1)
        Invoke-Command -ComputerName $Server -ScriptBlock {
            param($UserName, $DomainName, $LeafName)
            
            $FullUserName = "$DomainName\$UserName"
            try {
                # Ajout du compte de service au groupe d'administration local de la machine
                Add-LocalGroupMember -Group "Administrateurs" -Member $FullUserName -ErrorAction Stop | Out-Null
                Write-Host "  [OK] $FullUserName injecté dans le groupe local Administrateurs." -ForegroundColor Green
            } catch {
                Write-Host "  [INFO] $FullUserName fait déjà partie des Administrateurs locaux." -ForegroundColor Yellow
            }
            
            # Déclenchement de la configuration locale esclave V5.2
            $RemoteScript = "C:\temp\$LeafName"
            if (Test-Path $RemoteScript) {
                Write-Host "  [EXEC] Lancement de la configuration sur l'hôte distant..." -ForegroundColor Cyan
                & $RemoteScript
            }
        } -ArgumentList $UserName, $DomainName, $LeafName

    } else {
        Write-Host "  [ERREUR] Le serveur $Server ne répond pas aux requêtes ICMP (Ping)." -ForegroundColor Red
    }
}

# --- ÉTAPE 4 : CONSOLIDATION FINALE ET RAPPORT DE CONFORMITÉ ---
Write-Host "`n--- Récapitulatif des Logs de configuration ---" -ForegroundColor Cyan
Invoke-Command -ComputerName $Servers -ScriptBlock {
    $LogPath = "C:\temp\WinRM_Config_History.log"
    $LogContent = if (Test-Path $LogPath) { Get-Content $LogPath -Tail 1 } else { "Fichier introuvable" }
    
    [PSCustomObject]@{
        Serveur = $env:COMPUTERNAME
        Statut  = $LogContent
    }
} | Format-Table -AutoSize

Write-Host "`n=== VERIFICATION FINALE DES ECOUTEURS WINRM HTTPS ACTIVE (5986) ===" -ForegroundColor Yellow
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
} | Select-Object @{Name="Serveur"; Expression={$_.PSComputerName}}, Service, Port, Transport, Actif, Hostname, Cert_Thumb | Sort-Object Serveur | Format-Table -AutoSize