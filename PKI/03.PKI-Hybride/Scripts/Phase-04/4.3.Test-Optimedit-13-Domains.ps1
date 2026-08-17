<#
====================================================================================
 Script : 4.3.Test-Optimedit-13.Domains-SSL.ps1
 Auteur : Optimedi
 Objet  : Diagnostic DNS + TCP 443 + Certificat SSL (CN + Issuer + Expiration)
====================================================================================
#>

function Get-SSLCertificate {
    param(
        [string]$domain,
        [int]$port = 443
    )

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient($domain, $port)

        $sslStream = New-Object System.Net.Security.SslStream(
            $tcp.GetStream(),
            $false,
            { param($sender,$cert,$chain,$errors) return $true }
        )

        $sslStream.AuthenticateAsClient($domain)

        # Conversion en X509Certificate2 pour lire les infos avancées
        $cert2 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)

        return $cert2
    }
    catch {
        return $null
    }
}

# --- Liste des sous-domaines à tester ---
$domains = @(
    "achat.optimedit.eu",
    "blog.optimedit.eu",
    "ce.optimedit.eu",
    "client.optimedit.eu",
    "commercial.optimedit.eu",
    "comptabilite.optimedit.eu",
    "direction.optimedit.eu",
    "formation.optimedit.eu",
    "it.optimedit.eu",
    "juridique.optimedit.eu",
    "paie.optimedit.eu",
    "production.optimedit.eu",
    "rh.optimedit.eu"
)

Write-Host "`n=== DIAGNOSTIC GLOBAL Optimedit (DNS + HTTPS + Certificat SSL) ===" -ForegroundColor Cyan

$results = @()

foreach ($d in $domains) {

    Write-Host "`n------------------------------------------------------------"
    Write-Host "TEST DU DOMAINE : $d" -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------"

    $dnsOK = $false
    $tcpOK = $false
    $certStatus = "Non lu"

    # --- TEST DNS ---
    try {
        $dns = Resolve-DnsName $d -ErrorAction Stop
        $ip = ($dns | Where-Object { $_.Type -eq "A" }).IPAddress
        Write-Host "DNS OK : $d → $ip" -ForegroundColor Green
        $dnsOK = $true
    }
    catch {
        Write-Host "DNS FAIL : $d ne se résout pas" -ForegroundColor Red
        continue
    }

    # --- TEST TCP 443 ---
    $tcp = Test-NetConnection -ComputerName $d -Port 443
    if ($tcp.TcpTestSucceeded) {
        Write-Host "TCP 443 OK : connexion établie" -ForegroundColor Green
        $tcpOK = $true
    } else {
        Write-Host "TCP 443 FAIL : port 443 inaccessible" -ForegroundColor Red
        continue
    }

    # --- TEST CERTIFICAT SSL ---
    $cert = Get-SSLCertificate $d
    if ($cert -ne $null) {

        $cn = $cert.Subject
        $issuer = $cert.Issuer
        $exp = $cert.NotAfter.ToString("yyyy-MM-dd HH:mm")

        Write-Host "Certificat CN       : $cn" -ForegroundColor Green
        Write-Host "Émis par            : $issuer" -ForegroundColor Green
        Write-Host "Expiration          : $exp" -ForegroundColor Green

        $certStatus = "Valide — CN=$cn — Expire le $exp"
    }
    else {
        Write-Host "SSL FAIL : impossible de lire le certificat via TLS" -ForegroundColor Red
        $certStatus = "Échec lecture certificat"
    }

    # --- Ajout au tableau final ---
    $results += [PSCustomObject]@{
        Domaine = $d
        DNS = if ($dnsOK) { "OK" } else { "FAIL" }
        TCP443 = if ($tcpOK) { "OK" } else { "FAIL" }
        Certificat = $certStatus
    }
}

Write-Host "`n=== SYNTHÈSE DES RÉSULTATS ===" -ForegroundColor Magenta
$results | Format-Table -AutoSize
