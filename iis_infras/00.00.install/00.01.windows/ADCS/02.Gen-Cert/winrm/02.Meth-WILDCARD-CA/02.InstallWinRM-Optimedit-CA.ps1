
# nom script: 02.InstallWinRM-Optimedit.ps1
# Ce script copier le script 02.ConfigureWinRM-Optimedit-CA.ps1 sur les serveur cibles d'Ansible pour configurer winrm en https
# avec certificat delivré par ADCS de optimedit.eu

# 1. Définition des variables
$UserName = "admin_ansible"												# a adapter
$DomainName = "OPTIMEDIT.EU"											# a adapter
$Password = ConvertTo-SecureString "Dr/*-101977" -AsPlainText -Force	# a adapter
$Servers = @(
    "OPT-IIS-01", "OPT-IIS-02","OPT-IIS-03")							# a adapter

# 2. Vérification et Création du compte AD
Write-Host "--- Vérification du compte AD : $UserName ---" -ForegroundColor Cyan
if (-not (Get-ADUser -Filter "SamAccountName -eq '$UserName'")) {
    New-ADUser -Name $UserName -SamAccountName $UserName `
               -AccountPassword $Password -Enabled $true `
               -PasswordNeverExpires $true `
               -DisplayName "Ansible Root Account"
    
    # Activation du chiffrement AES 256 pour Kerberos
    Set-ADUser -Identity $UserName -KerberosEncryptionType AES256
	
	# Si coché, Decocher"Le compte est sensible et ne peut pas être délégué"
	Set-ADUser -Identity $UserName -AccountNotDelegated $false
	
    Write-Host "Compte $UserName créé avec succès." -ForegroundColor Green
} else {
    Write-Host "Le compte $UserName existe déjà." -ForegroundColor Yellow
}

# 3. Déploiement sur les serveurs distants
Write-Host "`n--- Configuration des serveurs cibles ---" -ForegroundColor Cyan

# 3. Déploiement sur les serveurs distants
Write-Host "`n--- Configuration des serveurs cibles ---" -ForegroundColor Cyan

foreach ($Server in $Servers) {
    Write-Host "Traitement de $Server..." -ForegroundColor White
    
    if (Test-Connection -ComputerName $Server -Count 1 -Quiet) {
        
        # Vérification/Création du dossier distant
        Invoke-Command -ComputerName $Server -ScriptBlock {
            if (-not (Test-Path "C:\temp")) {
                New-Item -Path "C:\temp" -ItemType Directory -Force | Out-Null
                Write-Host "  [OK] Dossier C:\temp créé." -ForegroundColor Green
            }
        }

        # Copie du script de configuration vers le serveur cible
        try {
            Copy-Item "C:\Scripts\02.ConfigureWinRM-Optimedit-CA.ps1" -Destination "\\$Server\C$\temp\" -ErrorAction Stop
            Write-Host "  [OK] Script de configuration copié." -ForegroundColor Green
        } catch {
            Write-Host "  [ERREUR] Échec de la copie vers $Server : $($_.Exception.Message)" -ForegroundColor Red
            continue # Passe au serveur suivant si la copie échoue
        }
        
        # Exécution des commandes distantes
        Invoke-Command -ComputerName $Server -ScriptBlock {
            param($UserName, $DomainName)
            
            # 1. Ajout au groupe Administrateurs Local
            $FullUserName = "$DomainName\$UserName"
            try {
                Add-LocalGroupMember -Group "Administrateurs" -Member $FullUserName -ErrorAction Stop
                Write-Host "  [OK] $FullUserName ajouté aux Administrateurs locaux." -ForegroundColor Green
            } catch {
                Write-Host "  [INFO] $FullUserName est déjà présent ou erreur d'ajout." -ForegroundColor Yellow
            }
            
            # 2. Exécution du script de configuration WinRM Local
            if (Test-Path "C:\temp\02.ConfigureWinRM-Optimedit-CA.ps1") {
                & "C:\temp\02.ConfigureWinRM-Optimedit-CA.ps1"
                Write-Host "  [OK] WinRM configuré pour Ansible." -ForegroundColor Green
            } else {
                Write-Host "  [ERREUR] Script de configuration introuvable sur le serveur distant." -ForegroundColor Red
            }
        } -ArgumentList $UserName, $DomainName

    } else {
        Write-Host "  [ERREUR] $Server est injoignable (Ping échoué)." -ForegroundColor Red
    }
}

# Pourquoi ce script est "blindé" pour ton projet ?

    #Chiffrement AES 256 : La commande Set-ADUser -KerberosEncryptionType AES256 est capitale pour que ton kinit sur Debian continue de fonctionner parfaitement avec ce nouveau compte.

    #Double action : Il ne se contente pas de donner les droits, il injecte aussi la configuration WinRM (port 5986, certificats) sur chaque machine.

    #Gestion des erreurs : Si un serveur est éteint (comme ADM02 tout à l'heure), le script passe au suivant sans planter.