<#
    3.2.1.grant_service_logon_rights.ps1
    Objet   : Accorder "Log on as a service" et "Perform volume maintenance tasks"
              aux comptes SVC_SQL_Engine et SVC_SQL_Agent
    Noeuds  : SQLS01 + SQLS02 (executer sur chaque noeud, en administrateur)
#>

$Accounts = @("optimedit\SVC_SQL_Engine","optimedit\SVC_SQL_Agent")
$TempCfg  = "$env:TEMP\secpol.cfg"

# INFO : # Le script peut afficher un avertissement gnéré par la commande secedit
# Le ùessage = "Le mappage entre les noms de compte et les ID de sécurité n'a pas été effectué" et "La tâche s'est terminée avec une erreur."
# Cela est un avertissement bénin émis par secedit /configure quand il rencontre un SID qu'il ne peut pas résoudre. 
# Dans ce cas, c'était probablement S-1-5-80-0 (compte système NT SERVICE\ALL SERVICES), qui n'est pas résolvable par secedit mais qui est légitime.

secedit /export /cfg $TempCfg | Out-Null 
$content = Get-Content $TempCfg

foreach ($Right in @("SeServiceLogonRight","SeManageVolumePrivilege")) {
    foreach ($Account in $Accounts) {
        $sid = (New-Object System.Security.Principal.NTAccount($Account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        $content = $content -replace "($Right\s*=\s*.*)", "`$1,*$sid"
    }
}

$content | Set-Content $TempCfg
secedit /configure /db secedit.sdb /cfg $TempCfg /areas USER_RIGHTS
Write-Host "Droits appliques : Log on as a service + Perform volume maintenance tasks" -ForegroundColor Green
