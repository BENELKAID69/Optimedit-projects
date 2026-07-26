<#
.SYNOPSIS
    Nom du script : 03.InstallWinRM-FQDN-CA-Optimedit.ps1
    Déploiement et configuration automatisée de WinRM HTTPS sur les serveurs cibles Optimedit.

.DESCRIPTION
    1. Vérifie/Crée le compte de service 'admin_ansible' dans l'AD avec chiffrement AES256.
    2. Teste la connectivité avec les serveurs distants.
    3. Copie le script de configuration locale vers le dossier C:\temp distant.
    4. Ajoute le compte admin aux administrateurs locaux du serveur cible.
    5. Exécute le script de configuration WinRM via une session distante.

.PREREQUIS
    - Le pare-feu doit être désactivé sur les serveurs distants ou les protocoles ICMP (Ping) et SMB (Port 445) autorisés.
    - Accès administratif au domaine OPTIMEDIT.EU.
#>

# V2

# 1. Définition des variables d'environnement
$UserName   = "admin_ansible"
$DomainName = "OPTIMEDIT.EU"
$Password   = ConvertTo-SecureString "Dr/*-101977" -AsPlainText -Force
$Servers = @(
    "OPT-IIS-01.optimedit.eu",
    "OPT-IIS-02.optimedit.eu",
    "OPT-IIS-03.optimedit.eu",
    "OPT-IIS-04.optimedit.eu",
    "OPT-IIS-05.optimedit.eu",
    "OPT-IIS-06.optimedit.eu",
    "OPT-IIS-07.optimedit.eu",
    "OPT-IIS-08.optimedit.eu"
)

# Chemin local du script de configuration à déployer
#$FileName = "C:\temp\03.ConfigureWinRM-FQDN-CA-Optimedit.ps1"
$FileName = "\\optimedit.eu\NETLOGON\03.ConfigureWinRM-FQDN-CA-Optimedit.ps1"
Test-Path $FileName

# Vérification de l'existence du fichier source avant de commencer
if (-not (Test-Path -Path $FileName)) {
    Write-Host "[STOP] Le fichier source $FileName est introuvable localement." -ForegroundColor Red
    return
}

# 2. Gestion du compte de service dans l'Active Directory
Write-Host "--- Vérification du compte AD : $UserName ---" -ForegroundColor Cyan
if (-not (Get-ADUser -Filter "SamAccountName -eq '$UserName'")) {
    New-ADUser -Name $UserName -SamAccountName $UserName `
               -AccountPassword $Password -Enabled $true `
               -PasswordNeverExpires $true `
               -DisplayName "Ansible Root Account"
    
    # Sécurisation Kerberos et délégation
    Set-ADUser -Identity $UserName -KerberosEncryptionType AES256
    Set-ADUser -Identity $UserName -AccountNotDelegated $false
    Write-Host "Compte $UserName créé avec succès." -ForegroundColor Green
} else {
    Write-Host "Le compte $UserName existe déjà." -ForegroundColor Yellow
}

# 3. Déploiement et exécution sur les serveurs distants
Write-Host "`n--- Configuration des serveurs cibles ---" -ForegroundColor Cyan

foreach ($Server in $Servers) {
    Write-Host "Traitement de $Server..." -ForegroundColor White
    
    # Test de connectivité initiale (ICMP requis)
    if (Test-Connection -ComputerName $Server -Count 1 -Quiet) {
        
        # Préparation du dossier de réception sur le serveur distant
        Invoke-Command -ComputerName $Server -ScriptBlock {
            if (-not (Test-Path "C:\temp")) {
                New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null
                Write-Host "  [OK] Dossier C:\temp créé sur le serveur distant." -ForegroundColor Green
            }
        }

        # Copie du script de configuration (SMB / Port 445 requis)
        try {
            Copy-Item -Path $FileName -Destination "\\$Server\C$\temp\" -ErrorAction Stop
            Write-Host "  [OK] Script de configuration copié via SMB." -ForegroundColor Green
        } catch {
            Write-Host "  [ERREUR] Échec de la copie vers $Server : $($_.Exception.Message)" -ForegroundColor Red
            continue 
        }
        
        # Exécution de la configuration WinRM locale via Invoke-Command
        Invoke-Command -ComputerName $Server -ScriptBlock {
            param($UserName, $DomainName, $PathOnRemote)
            
            # A. Ajout du compte de service au groupe Administrateurs Local
            $FullUserName = "$DomainName\$UserName"
            try {
                Add-LocalGroupMember -Group "Administrateurs" -Member $FullUserName -ErrorAction Stop
                Write-Host "  [OK] $FullUserName ajouté aux Administrateurs locaux." -ForegroundColor Green
            } catch {
                Write-Host "  [INFO] $FullUserName est déjà présent ou erreur d'ajout." -ForegroundColor Yellow
            }
            
            # B. Exécution dynamique du script copié
            $RemoteScript = "C:\temp\" + ($PathOnRemote.Split('\')[-1])
            
            if (Test-Path $RemoteScript) {
                & $RemoteScript
                Write-Host "  [OK] WinRM configuré pour Ansible via $RemoteScript" -ForegroundColor Green
            } else {
                Write-Host "  [ERREUR] Script introuvable sur le serveur distant ($RemoteScript)." -ForegroundColor Red
            }
        } -ArgumentList $UserName, $DomainName, $FileName

    } else {
        Write-Host "  [ERREUR] $Server est injoignable (Ping échoué). Vérifiez le pare-feu." -ForegroundColor Red
    }
}

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







