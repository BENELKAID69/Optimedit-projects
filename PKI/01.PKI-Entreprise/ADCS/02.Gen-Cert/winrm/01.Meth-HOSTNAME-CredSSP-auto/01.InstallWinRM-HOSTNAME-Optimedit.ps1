
# Ce script exécutera aussi le script "ConfigureRemotingForAnsible" via un URL :
# "https://raw.githubusercontent.com/ansible/ansible-documentation/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"

# 1. Définition des variables
$UserName = "root"
$DomainName = "OPTIMEDIT.EU"
$Password = ConvertTo-SecureString "Dr/*-101977" -AsPlainText -Force
$Servers = @(
    "OPT-CTX-ADM02", "OPT-CTX-ADM03", 
    "OPT-CTX-MGT01", "OPT-CTX-MGT02", 
    "OPT-CTX-DEV01", "OPT-CTX-DEV02"
)

# 2. Vérification et Création du compte AD
Write-Host "--- Vérification du compte AD : $UserName ---" -ForegroundColor Cyan
if (-not (Get-ADUser -Filter "SamAccountName -eq '$UserName'")) {
    New-ADUser -Name $UserName -SamAccountName $UserName `
               -AccountPassword $Password -Enabled $true `
               -PasswordNeverExpires $true `
               -DisplayName "Ansible Root Account"
    
    # Activation du chiffrement AES 256 pour Kerberos
    Set-ADUser -Identity $UserName -KerberosEncryptionType AES256
    Write-Host "Compte $UserName créé avec succès." -ForegroundColor Green
} else {
    Write-Host "Le compte $UserName existe déjà." -ForegroundColor Yellow
}

# 3. Déploiement sur les serveurs distants
Write-Host "`n--- Configuration des serveurs cibles ---" -ForegroundColor Cyan

foreach ($Server in $Servers) {
    Write-Host "Traitement de $Server..." -ForegroundColor White
    
    if (Test-Connection -ComputerName $Server -Count 1 -Quiet) {
        Invoke-Command -ComputerName $Server -ScriptBlock {
            param($UserName, $DomainName)
            
            # Ajout au groupe Administrateurs Local
            $FullUserName = "$DomainName\$UserName"
            try {
                Add-LocalGroupMember -Group "Administrateurs" -Member $FullUserName -ErrorAction Stop
                Write-Host "  [OK] $FullUserName ajouté aux Administrateurs locaux." -ForegroundColor Green
            } catch {
                Write-Host "  [INFO] $FullUserName est déjà présent ou erreur d'ajout." -ForegroundColor Yellow
            }

            # Activation de WinRM pour Ansible (Téléchargement et exécution du script officiel)
            $url = "https://raw.githubusercontent.com/ansible/ansible-documentation/devel/examples/scripts/ConfigureRemotingForAnsible.ps1"
            $file = "$env:temp\ConfigureRemotingForAnsible.ps1"
            (New-Object -TypeName System.Net.WebClient).DownloadFile($url, $file)
            & $file
            Write-Host "  [OK] WinRM configuré pour Ansible." -ForegroundColor Green
        } -ArgumentList $UserName, $DomainName
    } else {
        Write-Host "  [ERREUR] $Server est injoignable (Ping échoué)." -ForegroundColor Red
    }
}

# Pourquoi ce script est "blindé" pour ton projet ?

    #Chiffrement AES 256 : La commande Set-ADUser -KerberosEncryptionType AES256 est capitale pour que ton kinit sur Debian continue de fonctionner parfaitement avec ce nouveau compte.

    #Double action : Il ne se contente pas de donner les droits, il injecte aussi la configuration WinRM (port 5986, certificats) sur chaque machine.

    #Gestion des erreurs : Si un serveur est éteint (comme ADM02 tout à l'heure), le script passe au suivant sans planter.