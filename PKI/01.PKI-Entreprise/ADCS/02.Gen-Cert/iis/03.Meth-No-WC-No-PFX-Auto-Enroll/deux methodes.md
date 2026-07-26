C'est là que l'on touche à une subtilité importante d'ADCS. Par défaut, le mécanisme d'auto-enrôlement standard de Windows (qui se base sur l'identité de l'ordinateur dans l'Active Directory) ne peut récupérer **que** le FQDN réel de la machine (ex: `OPT-IIS-01.optimedit.eu`) et son nom NetBIOS. Il ne sait pas deviner tout seul vos 13 domaines métiers (comme `comptabilite.optimedit.eu`, `rh.optimedit.eu`, etc.) car ces informations n'existent pas dans l'objet ordinateur de l'AD.

Si vous voulez que chaque serveur IIS génère **automatiquement** et **individuellement** son propre certificat contenant son FQDN réel **ET** les 13 SAN de vos sites (sans fichier `.inf` manuel à chaque fois), vous avez deux excellentes stratégies.

---

## Stratégie 1 : L'enrôlement via Script Automatisé (Recommandé pour votre infra)

Puisque vous maîtrisez déjà le déploiement par script, c'est la méthode la plus propre. Au lieu de laisser Windows faire un auto-enrôlement "aveugle", votre script va construire la requête à la volée sur chaque serveur.

Le principe est simple : le script récupère dynamiquement le FQDN de la machine locale, y ajoute la liste fixe de vos 13 sites, et demande le certificat au nouveau modèle ADCS (qui doit être configuré pour **"Fournir dans la requête"**).

### Le script à intégrer dans votre Phase 2 :

```powershell
# --- CONFIGURATION DE LA DEMANDE ---
$FqdnLocal = "$env:COMPUTERNAME.$env:USERDNSDOMAIN".ToLower()
$TemplateName = "IIS-SAN-Auto-Enrollment" # Votre nouveau modèle ADCS
$FqdnCa   = "OPT-DC02.optimedit.eu"  
$CaName   = "Optimedit-CA"           

# Vos 13 domaines métiers fixes
$MetierDomains = @(
    "direction.optimedit.eu", "comptabilite.optimedit.eu", "paie.optimedit.eu",
    "rh.optimedit.eu", "ce.optimedit.eu", "it.optimedit.eu", 
    "production.optimedit.eu", "formation.optimedit.eu", "achat.optimedit.eu",
    "commercial.optimedit.eu", "client.optimedit.eu", "juridique.optimedit.eu",
    "blog.optimedit.eu", "optimedit.eu"
)

# On fusionne le FQDN réel de la machine + les 13 domaines
$AllSANs = @($FqdnLocal) + $MetierDomains

Write-Host "Préparation de la requête pour $FqdnLocal avec les 13 SAN..." -ForegroundColor Cyan

# Génération dynamique des extensions SAN pour la commande PowerShell
$AlternativeNames = $AllSANs | ForEach-Object { "dns=$_" }
$SanExtension = [string]::Join("&", $AlternativeNames)

# Utilisation de la commande moderne PowerShell de demande de certificat
$CertRequest = New-CertificateRequest -Subject "CN=$FqdnLocal" `
                                      -AlternativeName $AllSANs `
                                      -KeyExportable $true `
                                      -Type Machine `
                                      -Template $TemplateName `
                                      -CertStoreLocation "Cert:\LocalMachine\My"

# Soumission directe et automatique à la CA
$ConfigString = "$FqdnCa\$CaName"
$RequestPath = "C:\temp\request_local.req"
$ResponsePath = "C:\temp\response_local.cer"

# Export de la requête générée vers un fichier temporaire
[File]::WriteAllText($RequestPath, $CertRequest)

# Envoi à la CA et récupération du certificat
certreq.exe -submit -config $ConfigString $RequestPath $ResponsePath
certreq.exe -accept $ResponsePath

Write-Host "[SUCCÈS] Certificat individuel installé pour $FqdnLocal avec ses 13 SAN." -ForegroundColor Green

```

---

## Stratégie 2 : L'Auto-Enrôlement pur via les attributs AD (Sans script)

Si vous refusez l'usage d'un script et voulez que la tâche planifiée `AutomaticCertificateEnrollment` gère cela de manière 100 % native, il faut injecter vos 13 noms de domaine directement dans l'Active Directory pour chaque serveur.

Windows sait lire l'attribut **`servicePrincipalName` (SPN)** ou l'attribut **`dNSHostName`** d'un compte ordinateur lors de sa demande de certificat.

### Les étapes de configuration :

1. **Modifier le modèle sur la CA :** Dans l'onglet *Nom du sujet*, cochez *"Construire à partir de ces informations Active Directory"*, choisissez *Nom de l'objet : CN*, et cochez la case **Nom DNS** dans les noms de sujet alternatifs.
2. **Ajouter les alias sur les comptes ordinateurs :** Via la console *Utilisateurs et ordinateurs Active Directory* (en mode fonctionnalités avancées) ou par un script unique, vous devez peupler l'attribut `servicePrincipalName` de vos serveurs (ex: `OPT-IIS-01`) avec les adresses des sites :
* `HOST/comptabilite.optimedit.eu`
* `HOST/rh.optimedit.eu`
* (etc. pour les 13 domaines).



Dès que la tâche d'auto-enrôlement s'exécutera sur le serveur, elle lira ses SPN dans l'AD et la CA générera un certificat sur mesure contenant le FQDN réel de la machine ainsi que les 13 sites en SAN.

---

## 💡 Mon conseil d'expert pour vos fermes IIS

La **Stratégie 1 (via script `New-CertificateRequest`)** est de loin la plus robuste et la plus simple à maintenir pour votre architecture. Elle vous évite de "polluer" les attributs SPN de vos contrôleurs de domaine (ce qui peut parfois créer des conflits de ticket Kerberos si plusieurs serveurs IIS partagent les mêmes SPN d'applications).

Avec le script ci-dessus intégré dans votre orchestrateur, le déploiement sur vos 10 serveurs se fait en un clic, et chacun aura son certificat unique nominatif + les 13 sites métiers.