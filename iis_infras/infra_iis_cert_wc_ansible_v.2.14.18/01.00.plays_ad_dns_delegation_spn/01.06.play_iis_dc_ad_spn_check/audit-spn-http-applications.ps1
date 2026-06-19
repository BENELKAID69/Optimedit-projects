# ==============================================================================
# Script : Audit-IIS-Applications-SPN.ps1
# Description : Audit des comptes de service svc_* avec éclatement des SPN HTTP
# ==============================================================================

Get-ADUser -Filter "Name -like 'svc_*'" -Properties ServicePrincipalNames | ForEach-Object {
    $User = $_
    
    # Filtrer uniquement les SPN HTTP pour ce compte
    $HttpSpns = $User.ServicePrincipalNames | Where-Object { $_ -like "http/*" }
    
    # Initialisation des variables de colonnes
    $SpnLong = $null
    $SpnShort = $null
    
    # Séparation dynamique du SPN Long (avec un point) et du SPN Short
    foreach ($Spn in $HttpSpns) {
        if ($Spn -match "\.") {
            $SpnLong = $Spn
        } else {
            $SpnShort = $Spn
        }
    }
    
    # Génération de l'objet de sortie personnalisé
    [PSCustomObject]@{
        Name              = $User.Name
        UserPrincipalName = $User.UserPrincipalName
        SPN_Long          = $SpnLong
        SPN_Short         = $SpnShort
    }
} | Format-Table -AutoSize

# Comment corriger tes SPN pour qu'ils matchent tes applications ?

# 01. Supprimer l'ancien SPN erroné :
# setspn -d http/svc_direction.optimedit.eu OPTIMEDIT\svc_direction
# setspn -d http/svc_direction OPTIMEDIT\svc_direction

# 02. Ajouter le VRAI SPN applicatif (Règle d'or) :
# setspn -s HTTP/direction.optimedit.eu OPTIMEDIT\svc_direction
# setspn -s HTTP/direction OPTIMEDIT\svc_direction


# Remove-ADUser -Identity "svc_oracle" -Confirm:$false

