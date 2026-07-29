<# 
    Script : 1.3.Validation.Configuration.Ferme.ARR.ps1
    Objectif : Valider la configuration HTTP 80 + ARR + DNS pour la Phase 1.3
    Auteur : Driss / Optimedit
    Version : 2.0
#>

Write-Host "===== VALIDATION CONFIGURATION FERME ARR (PHASE 1.3) =====" -ForegroundColor Cyan

# ============================================================
# 1. Vérifier la connectivité HTTP 80 vers les 6 backends
# ============================================================

$Backends = @(
    "OPT-IIS-01.optimedit.eu",
    "OPT-IIS-02.optimedit.eu",
    "OPT-IIS-03.optimedit.eu",
    "OPT-IIS-04.optimedit.eu",
    "OPT-IIS-05.optimedit.eu",
    "OPT-IIS-06.optimedit.eu"
)

Write-Host "`n--- TEST 1 : Connectivité HTTP 80 vers les backends ---" -ForegroundColor Yellow

foreach ($b in $Backends) {
    try {
        $ip = (Resolve-DnsName $b -ErrorAction Stop).IPAddress
        $result = Test-NetConnection $ip -Port 80
        if ($result.TcpTestSucceeded) {
            Write-Host "OK : $b ($ip) répond sur le port 80" -ForegroundColor Green
        } else {
            Write-Host "ERREUR : $b ($ip) ne répond pas sur le port 80" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "ERREUR : Résolution DNS impossible pour $b" -ForegroundColor Red
    }
}

# ============================================================
# 2. Vérifier les 13 sites via ARR (HTTP 80)
# ============================================================

$Sites = @(
    "achat","blog","ce","client","commercial","comptabilite",
    "direction","formation","it","juridique","paie","production","rh"
)

Write-Host "`n--- TEST 2 : Vérification des 13 sites via ARR ---" -ForegroundColor Yellow

foreach ($s in $Sites) {
    $fqdn = "$s.optimedit.eu"
    try {
        $r = Invoke-WebRequest -Uri "http://$fqdn" -UseBasicParsing
        Write-Host "OK : $fqdn (Status $($r.StatusCode))" -ForegroundColor Green
    }
    catch {
        Write-Host "ERREUR : $fqdn ne répond pas via ARR" -ForegroundColor Red
    }
}

# ============================================================
# 3. Vérifier la ferme ARR (Health Check)
# ============================================================

Write-Host "`n--- TEST 3 : Santé de la ferme ARR ---" -ForegroundColor Yellow

try {
    $farm = Get-WebConfiguration "/system.applicationHost/serverFarms/Optimedit-Web-Farm"
    Write-Host "OK : La ferme Optimedit-Web-Farm est présente" -ForegroundColor Green
}
catch {
    Write-Host "ERREUR : La ferme Optimedit-Web-Farm n'existe pas" -ForegroundColor Red
}

# ============================================================
# 4. Vérifier la règle serveur ARR
# ============================================================

Write-Host "`n--- TEST 4 : Règle serveur ARR ---" -ForegroundColor Yellow

try {
    $serverRules = Get-WebConfiguration "/system.applicationHost/rewrite/rules"
    $ruleFarm = $serverRules.Collection | Where-Object { $_.Action.Url -like "*Optimedit-Web-Farm*" }

    if ($ruleFarm) {
        Write-Host "OK : Règle serveur ARR trouvée : $($ruleFarm.Name)" -ForegroundColor Green
    } else {
        Write-Host "ERREUR : Aucune règle serveur ARR trouvée" -ForegroundColor Red
    }
}
catch {
    Write-Host "ERREUR : Impossible de lire les règles serveur ARR" -ForegroundColor Red
}

# ============================================================
# 5. Vérifier les règles site-par-site
# ============================================================

Write-Host "`n--- TEST 5 : Règles ReverseProxyInboundRule1 sur chaque site ---" -ForegroundColor Yellow

foreach ($s in $Sites) {
    try {
        $siteRules = Get-WebConfiguration "/system.webServer/rewrite/rules" -PSPath "IIS:\Sites\$s"
        $rpRule = $siteRules.Collection | Where-Object { $_.Name -like "*ReverseProxy*" }

        if ($rpRule) {
            Write-Host "OK : Règle ReverseProxy trouvée pour $s" -ForegroundColor Green
        } else {
            Write-Host "ERREUR : Pas de règle ReverseProxy pour $s" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "ERREUR : Impossible de lire les règles pour $s" -ForegroundColor Red
    }
}

# ============================================================
# 6. Vérifier que le DNS pointe vers OPT-RP-01
# ============================================================

Write-Host "`n--- TEST 6 : Vérification DNS (A -> OPT-RP-01) ---" -ForegroundColor Yellow

foreach ($s in $Sites) {
    $fqdn = "$s.optimedit.eu"
    try {
        $dns = Resolve-DnsName $fqdn -ErrorAction Stop
        if ($dns.IPAddress -eq "192.168.3.200") {
            Write-Host "OK : $fqdn -> 192.168.3.200" -ForegroundColor Green
        } else {
            Write-Host "ERREUR : $fqdn pointe vers $($dns.IPAddress)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "ERREUR : DNS introuvable pour $fqdn" -ForegroundColor Red
    }
}

# ============================================================
# 7A. Vérifier que les backends répondent depuis OPT-RP-01 (normal)
# ============================================================

Write-Host "`n--- TEST 7A : Backends accessibles depuis OPT-RP-01 (normal) ---" -ForegroundColor Yellow

foreach ($b in $Backends) {
    try {
        Invoke-WebRequest -Uri "http://$b" -UseBasicParsing
        Write-Host "OK : $b répond depuis OPT-RP-01 (normal)" -ForegroundColor Green
    }
    catch {
        Write-Host "ERREUR : $b ne répond pas depuis OPT-RP-01" -ForegroundColor Red
    }
}

# ============================================================
# 7B. Vérifier que les backends ne répondent pas depuis un poste LAN
# ============================================================

Write-Host "`n--- TEST 7B : Backends NON accessibles depuis un poste LAN (à exécuter sur poste LAN) ---" -ForegroundColor Yellow
Write-Host "NOTE : Ce test doit être exécuté sur un poste LAN/VPN NON OPT-RP-01" -ForegroundColor Cyan

# ============================================================
# 8. Vérifier que les sites ne répondent pas depuis les backends
# ============================================================

Write-Host "`n--- TEST 8 : Vérifier que les sites ne répondent pas depuis les backends ---" -ForegroundColor Yellow

foreach ($s in $Sites) {
    foreach ($b in $Backends) {
        try {
            Invoke-WebRequest -Uri "http://$b" -Headers @{Host="$s.optimedit.eu"} -UseBasicParsing
            Write-Host "OK : $s répond depuis $b (normal pour OPT-RP-01)" -ForegroundColor Green
        }
        catch {
            Write-Host "OK : $s ne répond pas depuis $b (normal pour LAN)" -ForegroundColor Green
        }
    }
}

# ============================================================
# 9. Résumé final
# ============================================================

Write-Host "`n===== VALIDATION PHASE 1.3 TERMINÉE =====" -ForegroundColor Cyan
