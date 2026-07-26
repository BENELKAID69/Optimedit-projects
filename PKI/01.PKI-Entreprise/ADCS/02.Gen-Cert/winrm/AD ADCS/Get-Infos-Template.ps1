
Import-Module ActiveDirectory

$TemplateName = "Ansible-WinRM-FQDN-SERVERS" # a adapter # ICI modele non .PFX - Nom du sujet = Construire à partir des information AD - valable auto-enrollement
$ConfigConf = (Get-ADRootDSE).configurationNamingContext
$Path = "CN=$TemplateName,CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigConf"

Get-ADObject -Identity $Path -Properties * | Select-Object `
    @{L="Nom"; E={$_.displayName}}, `
    @{L="Schema_Version"; E={$_."msPKI-Template-Schema-Version"}}, `
    @{L="Exportable"; E={if($_."msPKI-Private-Key-Flag" -band 0x10){"OUI"}else{"NON"}}}, `
    @{L="Validite"; E={$_.pkiExpirationPeriod[1] / 1}}
	
Get-ADObject -Identity $Path -Properties *