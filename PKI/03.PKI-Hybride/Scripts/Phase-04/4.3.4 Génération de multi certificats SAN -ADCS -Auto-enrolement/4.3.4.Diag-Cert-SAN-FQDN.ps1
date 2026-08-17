
#00
Import-Module ActiveDirectory

$TemplateName = "IIS-FQDN-SAN-Auto-Enrollment" # a adapter le modele
$ConfigConf = (Get-ADRootDSE).configurationNamingContext
$Path = "CN=$TemplateName,CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigConf"

Get-ADObject -Identity $Path -Properties * | Select-Object `
    @{L="Nom"; E={$_.displayName}}, `
    @{L="Schema_Version"; E={$_."msPKI-Template-Schema-Version"}}, `
    @{L="Exportable"; E={if($_."msPKI-Private-Key-Flag" -band 0x10){"OUI"}else{"NON"}}}, `
    @{L="Validite"; E={$_.pkiExpirationPeriod[1] / 1}}
	
Get-ADObject -Identity $Path -Properties *


#01
$ConfigConf = (Get-ADRootDSE).configurationNamingContext
$obj = Get-ADObject -Filter "cn -eq 'IIS-FQDN-SAN-Auto-Enrollment'" `
    -SearchBase "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigConf"

Write-Host "Longueur du nom : $($obj.Name.Length)"  # doit afficher 29
certutil -SetCATemplates "+$($obj.Name)"



#02
Get-WinEvent -LogName "Application" -MaxEvents 50 |
    Where-Object { $_.ProviderName -like "*CertSvc*" -or $_.ProviderName -like "*CertificationAuthority*" } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List



#03 comparaison avec autre modèle
$path1 = "CN=IIS-SAN-PFX-Non-Auto-Reinscription,CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigConf"
$path2 = "CN=IIS-FQDN-SAN-Auto-Enrollment,CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigConf"

$t1 = Get-ADObject -Identity $path1 -Properties revision, "msPKI-Template-Schema-Version", "msPKI-Template-Minor-Revision", "pKIDefaultCSPs"
$t2 = Get-ADObject -Identity $path2 -Properties revision, "msPKI-Template-Schema-Version", "msPKI-Template-Minor-Revision", "pKIDefaultCSPs"

Compare-Object $t1 $t2 -Property revision, "msPKI-Template-Schema-Version", "msPKI-Template-Minor-Revision"


