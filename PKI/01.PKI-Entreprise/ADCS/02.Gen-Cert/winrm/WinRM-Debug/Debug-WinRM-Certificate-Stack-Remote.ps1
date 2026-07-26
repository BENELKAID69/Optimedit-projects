$Servers = @("OPT-IIS-01","OPT-IIS-02","OPT-IIS-03","OPT-IIS-04", "OPT-IIS-05","OPT-IIS-06")
$TargetOID = "1.3.6.1.4.1.311.21.8.221933.7254082.8798593.2679569.10943928.7.13152591.13092389"

Invoke-Command -ComputerName $Servers -ScriptBlock {
    param($OID)
    
    # 1. Identification du certificat
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
        ($_.Extensions | Where-Object { $_.Oid.Value -eq "1.3.6.1.4.1.311.21.7" }).Format(0) -match $OID
    } | Sort-Object NotBefore -Descending | Select-Object -First 1

    # 2. Vérification des couches (Booléens)
    $hasCert = $null -ne $cert
    $thumb = if($hasCert){$cert.Thumbprint}else{"NOT_FOUND"}
    
    $bindingOk = (netsh http show sslcert ipport=0.0.0.0:5986) -match $thumb
    $listenerOk = (winrm enumerate winrm/config/listener) -match $thumb
    
    # 3. Comptage des certificats totaux dans le magasin
    $totalCerts = (Get-ChildItem Cert:\LocalMachine\My).Count

    # Retour de l'objet essentiel
    [PSCustomObject]@{
        Serveur      = $env:COMPUTERNAME
        WinRM_HTTPS  = if($bindingOk -and $listenerOk){"OK"}else{"ERREUR"}
        Thumbprint   = $thumb
        Exp_Date     = if($hasCert){$cert.NotAfter.ToString("dd/MM/yy")}else{"N/A"}
        Nb_Certs_Store = $totalCerts
    }
} -ArgumentList $TargetOID | Format-Table -AutoSize