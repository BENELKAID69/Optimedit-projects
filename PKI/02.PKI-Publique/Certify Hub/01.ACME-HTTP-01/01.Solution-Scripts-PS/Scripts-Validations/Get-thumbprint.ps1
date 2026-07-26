$urls = @("https://srv-web-02.optimedit.eu", "https://srv-web-03.optimedit.eu","https://api-rest.optimedit.eu")

foreach ($url in $urls) {
    try {
        $request = [System.Net.HttpWebRequest]::Create($url)
        $request.ServerCertificateValidationCallback = { $true } # Ignore les erreurs de chaîne de confiance pour la lecture seule
        $request.GetResponse() | Out-Null
        $cert = $request.ServicePoint.Certificate
        
        Write-Host "URL : $url" -ForegroundColor Cyan
        Write-Host "Thumbprint : $($cert.GetCertHashString())" -ForegroundColor Green
        Write-Host "-------------------------------------------"
    }
    catch {
        Write-Host "Échec de connexion à $url : $($_.Exception.Message)" -ForegroundColor Red
    }
}