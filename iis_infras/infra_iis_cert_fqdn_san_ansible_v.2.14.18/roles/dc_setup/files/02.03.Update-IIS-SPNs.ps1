# ==============================================================================
# Emplacement : roles/dc_setup/files/Update-IIS-SPNs.ps1
# Description : Nettoyage des anciens SPN erronés et injection des vrais SPN HTTP
# ==============================================================================

# Récupération des arguments passés par Ansible
param (
    [string]$DomainFQDN,
    [string]$DomainNetBIOS
)

Import-Module ActiveDirectory

# Liste stricte de tes 13 applications (doit correspondre aux noms de tes sites)
$Apps = @("achat", "blog", "ce", "client", "commercial", "comptabilite", "direction", "formation", "it", "juridique", "paie", "production", "rh")

foreach ($AppName in $Apps) {
    $AccountName = "svc_$AppName"
    $SamAccount  = "$DomainNetBIOS\$AccountName"
    
    # 1. Définition des SPN obsolètes/erronés actuels à supprimer
    $BadSpnLong  = "http/$AccountName.$DomainFQDN"
    $BadSpnShort = "http/$AccountName"
    
    # 2. Définition des VRAIS SPN applicatifs conformes à Kerberos
    $GoodSpnLong  = "http/$AppName.$DomainFQDN"
    $GoodSpnShort = "http/$AppName"
    
    # Suppression des anciens SPN (l'opérateur *>$null évite de faire planter le script si déjà absents)
    & setspn -d $BadSpnLong $SamAccount *>$null
    & setspn -d $BadSpnShort $SamAccount *>$null
    
    # Injection des vrais SPN (L'option -s vérifie les doublons à l'échelle de la forêt AD)
    & setspn -s $GoodSpnLong $SamAccount *>$null
    & setspn -s $GoodSpnShort $SamAccount *>$null
}
