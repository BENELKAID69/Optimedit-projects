$PollutedServers = @("OPT-IIS-01", "OPT-IIS-02")
$TargetOID = "1.3.6.1.4.1.311.21.8.221933.7254082.8798593.2679569.10943928.7.13152591.13092389"

Invoke-Command -ComputerName $PollutedServers -ScriptBlock {
    param($OID)
    
    # 1. Identifier précisément le certificat WinRM Actuel (à préserver)
    $ActiveWinRMCert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $ext = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
        if ($null -ne $ext) { $ext.Format(0) -match $OID } else { $false }
    } | Sort-Object NotBefore -Descending | Select-Object -First 1

    if ($null -eq $ActiveWinRMCert) {
        Write-Error "[-] Impossible de trouver le certificat WinRM actif sur $env:COMPUTERNAME. Annulation par sécurité."
        return
    }

    $ActiveThumbprint = $ActiveWinRMCert.Thumbprint
    Write-Host "--- Nettoyage sur $env:COMPUTERNAME ---" -ForegroundColor Cyan
    Write-Host "[i] Certificat WinRM à conserver : $ActiveThumbprint" -ForegroundColor Gray

    # 2. Lister et supprimer les certificats redondants (Hostname ou FQDN)
    # On exclut le certificat actif, le CA, et Citrix.
    $CertsToDelete = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $_.Thumbprint -ne $ActiveThumbprint -and 
        $_.Subject -notmatch "Optimedit-CA" -and
        $_.Subject -notmatch "citrix.optimedit.eu" -and
        ($_.Subject -match $env:COMPUTERNAME)
    }

    foreach ($Cert in $CertsToDelete) {
        try {
            Write-Host "[-] Suppression : $($Cert.Subject) (Exp: $($Cert.NotAfter))" -ForegroundColor Yellow
            Remove-Item -Path $Cert.PSPath -Confirm:$false
        } catch {
            Write-Host "[!] Erreur lors de la suppression de $($Cert.Thumbprint)" -ForegroundColor Red
        }
    }
    
    Write-Host "[OK] Nettoyage terminé sur $env:COMPUTERNAME.`n" -ForegroundColor Green
} -ArgumentList $TargetOID