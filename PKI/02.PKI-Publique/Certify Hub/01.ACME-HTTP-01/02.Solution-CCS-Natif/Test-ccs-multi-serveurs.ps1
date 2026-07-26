# Test-ccs-multi-serveurs.ps1
$servers = @("SRV-WEB-02", "SRV-WEB-03")
$expectedThumbprint = "EC843D938E4C974B6636AABC609EDD1F333555B3"

Write-Host "`n=== 1. Vérification de la SOURCE du certificat (binding IIS) ===" -ForegroundColor Cyan
foreach ($srv in $servers) {
    Invoke-Command -ComputerName $srv -ScriptBlock {
        $binding = Get-WebBinding -Name "Default Web Site" -Protocol https
        $ccs = Get-IISCentralCertProvider

        $sourceCCS = ($binding.sslFlags -band 2) -ne 0 -and [string]::IsNullOrEmpty($binding.certificateHash)

        [PSCustomObject]@{
            Serveur          = $env:COMPUTERNAME
            BindingInfo      = $binding.bindingInformation
            SslFlags         = $binding.sslFlags
            CertHashLocal    = if ($binding.certificateHash) { $binding.certificateHash } else { "(vide)" }
            CCS_Enabled      = $ccs.Enabled
            SourceReelle     = if ($sourceCCS) { "✅ CCS" } else { "⚠️ Magasin local (pas CCS)" }
        }
    }
}

Write-Host "`n=== 2. Vérification du certificat RÉELLEMENT présenté (TLS réseau) ===" -ForegroundColor Cyan
$urls = @(
    "https://api-rest.optimedit.eu"
    #"https://srv-web-02.optimedit.eu", # après migration de CCS url ne fonctionnera pas car SNI activé
    #"https://srv-web-03.optimedit.eu" # après migration de CCS url ne fonctionnera pas car SNI activé
)
foreach ($url in $urls) {
    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.ServerCertificateValidationCallback = { $true }
        $request.GetResponse() | Out-Null
        $thumb = $request.ServicePoint.Certificate.GetCertHashString()
        $match = if ($thumb -eq $expectedThumbprint) { "✅ Conforme" } else { "❌ DIFFÉRENT" }

        [PSCustomObject]@{
            URL        = $url
            Thumbprint = $thumb
            Statut     = $match
        }
    }
    catch {
        Write-Host "Échec sur $url : $($_.Exception.Message)" -ForegroundColor Red
    }
} 
