<#
    3.2.0.create_sql_service_accounts.ps1
    Objet   : Creer les comptes de service SQL Server dans Active Directory
    Noeud   : DC03 (controleur de domaine) - necessite le module ActiveDirectory
#>

Import-Module ActiveDirectory

$Domain   = "optimedit.eu"
$OU       = "OU=Service Accounts,DC=optimedit,DC=eu"   # adapter a l'arborescence AD reelle
$Accounts = @("SVC_SQL_Engine","SVC_SQL_Agent")

foreach ($Account in $Accounts) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Account'" -ErrorAction SilentlyContinue)) {
        $Password = Read-Host -Prompt "Mot de passe pour $Account" -AsSecureString
        New-ADUser -Name $Account -SamAccountName $Account `
                   -UserPrincipalName "$Account@$Domain" `
                   -Path $OU -AccountPassword $Password `
                   -PasswordNeverExpires $true -Enabled $true
        Write-Host "Compte cree : $Account" -ForegroundColor Green
    } else {
        Write-Host "Compte deja existant : $Account" -ForegroundColor Yellow
    }
}
