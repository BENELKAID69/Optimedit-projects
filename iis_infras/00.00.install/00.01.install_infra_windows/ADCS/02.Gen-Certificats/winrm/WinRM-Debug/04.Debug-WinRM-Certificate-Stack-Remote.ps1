

$TargetServers = @("OPT-IIS-01", "OPT-IIS-02","OPT-IIS-03")
# Ton OID de modèle pour identifier avec certitude le bon certificat WinRM
$TargetOID = "1.3.6.1.4.1.311.21.8.221933.7254082.8798593.2679569.10943928.7.13152591.13092389"

Invoke-Command -ComputerName $TargetServers -ScriptBlock {
    param($OID)

    # 1. Identifier le certificat WinRM FQDN (celui à garder absolument)
    $WinRMCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $ext = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
        if ($null -ne $ext) { $ext.Format(0) -match $OID } else { $false }
    } | Select-Object -First 1

    if ($null -eq $WinRMCert) {
        Write-Warning "Certificat WinRM introuvable sur $env:COMPUTERNAME. Nettoyage annulé."
        return
    }

    $KeepThumbprints = @($WinRMCert.Thumbprint)

    # 2. Identifier le certificat Citrix (à garder aussi)
    $CitrixCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -match "citrix.optimedit.eu" }
    if ($null -ne $CitrixCert) { $KeepThumbprints += $CitrixCert.Thumbprint }

    Write-Host "--- Nettoyage de $env:COMPUTERNAME ---" -ForegroundColor Cyan

    # 3. Supprimer tout le reste (Vides, CA mal placée, anciens Hostnames)
    $ToDelete = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $KeepThumbprints -notcontains $_.Thumbprint }

    foreach ($cert in $ToDelete) {
        $reason = if ([string]::IsNullOrWhiteSpace($cert.Subject)) { "Vide" } else { $cert.Subject }
        Write-Host "[-] Suppression de : $reason" -ForegroundColor Yellow
        Remove-Item -Path $cert.PSPath -Force
    }

    Write-Host "[OK] Magasin 'My' nettoyé. Ne reste que WinRM et Citrix.`n" -ForegroundColor Green
} -ArgumentList $TargetOID