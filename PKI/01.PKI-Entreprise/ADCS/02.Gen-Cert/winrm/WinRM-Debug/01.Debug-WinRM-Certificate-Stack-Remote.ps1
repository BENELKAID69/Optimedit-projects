$Servers = @("OPT-IIS-01","OPT-IIS-02","OPT-IIS-03","OPT-IIS-04", "OPT-IIS-05","OPT-IIS-06")
$TargetOID = "1.3.6.1.4.1.311.21.8.221933.7254082.8798593.2679569.10943928.7.13152591.13092389"

Invoke-Command -ComputerName $Servers -ScriptBlock {
    param($OID)
    
    # 1. Identification du certificat avec protection contre les valeurs nulles
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        $ext = $_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }
        if ($null -ne $ext) { $ext.Format(0) -match $OID } else { $false }
    } | Sort-Object NotBefore -Descending | Select-Object -First 1

    # 2. Vérification des couches
    $hasCert = $null -ne $cert
    $thumb = if($hasCert){$cert.Thumbprint}else{"NON_TROUVE"}
    
    $bindingOk = (netsh http show sslcert ipport=0.0.0.0:5986) -match $thumb
    $listenerOk = (winrm enumerate winrm/config/listener) -match $thumb
    
    # 3. Comptage total
    $totalCerts = (Get-ChildItem Cert:\LocalMachine\My).Count

    # Retour de l'objet propre
    [PSCustomObject]@{
        Serveur      = $env:COMPUTERNAME
        WinRM_HTTPS  = if($bindingOk -and $listenerOk){"OK"}else{"ERREUR"}
        Thumbprint   = $thumb
        Expiration   = if($hasCert){$cert.NotAfter.ToString("dd/MM/yy")}else{"N/A"}
        Certs_Store  = $totalCerts
    }
} -ArgumentList $TargetOID | Select-Object Serveur, WinRM_HTTPS, Thumbprint, Expiration, Certs_Store | Format-Table -AutoSize



