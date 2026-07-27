<div align="center">

# 🗄️ CertifyHub — Migration vers le Magasin Centralisé (CCS)
# README-Certify-CCS-Task.md

### Migration du déploiement de certificats de PowerShell vers le Centralized Certificate Store (CCS) IIS
**Certify Management Hub → Stockage UNC Centralisé (`\API-REST\CCSStore`) → IIS SNI**

![Certify The Web](https://img.shields.io/badge/Certify-Management%20Hub-2E7D32?style=for-the-badge)
![IIS](https://img.shields.io/badge/IIS-Centralized%20Store-0078D4?style=for-the-badge&logo=windows&logoColor=white)
![Architecture](https://img.shields.io/badge/Architecture-CCS%20+%20SNI-FF6F00?style=for-the-badge)
![Status](https://img.shields.io/badge/Status-Production%20Ready-brightgreen?style=for-the-badge)

</div>

---

## ✨ Vue d'ensemble de la migration

> Remplacement de l'ancien script PowerShell de distribution à distance par une **intégration native du Magasin Centralisé (CCS) de Windows IIS**, pilotée directement par le Certify Management Hub. Les serveurs backends lisent désormais les certificats à la volée directement depuis le partage sécurisé.

<table>
<tr>
<td width="50%" valign="top">

### 🎯 Objectifs & Bénéfices

- 🗑️ **Suppression du script PowerShell** de déploiement à distance et de sa maintenance
- 📂 **Centralisation native** des certificats dans un dossier UNC (`\API-REST\CCSStore`)
- 🌐 **Activation de l'indicateur SNI** obligatoire sur les fermes IIS backends (`SRV-WEB-02` / `SRV-WEB-03`)
- 🔒 **Conservation intacte du challenge HTTP-01** pour `api-rest.optimedit.eu` (aucune modification ACME requise)
- 🚀 **Automatisation transparente** gérée par le provider natif Certify (`Certify.Providers.DeploymentTasks.CCS`)

</td>
<td width="50%" valign="top">

### 🧭 Pipeline Architectural Cible

```mermaid
graph TD
    A[🔁 Let's Encrypt<br/>Challenge HTTP-01] --> B[📦 Certify Hub<br/>Génération PFX interne]
    B --> C[📁 Tâche CCS<br/>Export UNC direct]
    C --> D[🌐 Partage \API-REST\CCSStore<br/>api-rest.optimedit.eu.pfx]
    D --> E[🖥️ SRV-WEB-02<br/>Lecture à la volée (SNI)]
    D --> F[🖥️ SRV-WEB-03<br/>Lecture à la volée (SNI)]
```

</td>
</tr>
</table>

---

## 📁 Topologie et Environnement

| Équipement | Rôle | IP / Chemin | Détails techniques |
|---|---|---|---|
| **API-REST** | Orchestrateur & Reverse Proxy | `192.168.1.125` | Héberge le Certify Management Hub et le partage `\API-REST\CCSStore` |
| **SRV-WEB-02** | Backend IIS 1 | `192.168.1.33` | Pointé vers le CCS avec SNI actif (`SslFlags = 3`) |
| **SRV-WEB-03** | Backend IIS 2 | `192.168.1.169` | Pointé vers le CCS avec SNI actif (`SslFlags = 3`) |
| **Certificat** | Mono-domaine cible | `api-rest.optimedit.eu` | Validé via HTTP-01, stocké au format PFX standard |

---

## ⚙️ Étape 1 : Prérequis et Partage UNC

Sur le serveur orchestrateur **API-REST**, préparez le stockage centralisé :

1. Créer le dossier local : `C:\CCSStore`
2. Configurer le partage réseau : `\API-REST\CCSStore`
3. **Droits NTFS & Partage :**
   - 📖 **Lecture :** Comptes machine des backends (`SRV-WEB-02$`, `SRV-WEB-03$`) + compte de service de lecture IIS (`OPTIMEDIT\svc_certify`).
   - ✍️ **Écriture :** Compte exécutant le Certify Hub (`LocalSystem` sur API-REST).

> 💡 **Note d'architecture :** Comme le Hub s'exécute en `LocalSystem` sur `API-REST` et que le partage y est hébergé, l'écriture du fichier `<hostname>.pfx` s'effectue directement sur le disque local sans authentification réseau complexe.

---

## 🎛️ Étape 2 : Configuration de la Tâche CCS dans le Hub Certify

Dans le **Certify Management Hub** (`api-rest.optimedit.eu` → Tasks → Deployment Tasks), ajoutez la tâche native :

| Paramètre du Hub | Valeur / Configuration |
|---|---|
| **Task Type** | `Deploy to Centralized Certificate Store (CCS)` *(Provider : `Certify.Providers.DeploymentTasks.CCS`)* |
| **Display Name** | `Deploy-to-CCS` |
| **Trigger** | `Run On Success` |
| **Run task even if previous task step failed** | ❌ Décoché |
| **Target Type** | `Local (as current service user)` |
| **Destination Path** | `\API-REST\CCSStore` |

---

## 💻 Étape 3 : Configuration des Serveurs IIS Backends

Sur chaque serveur backend (`SRV-WEB-02` et `SRV-WEB-03`) :

### 1. Installation de la fonctionnalité CCS
```powershell
# Installation du module Centralized Certificate Support pour IIS
Install-WindowsFeature Web-CertProvider -IncludeManagementTools
```

### 2. Activation du CCS via PowerShell
```powershell
$readCred = Get-Credential -Message "Compte avec accès lecture au partage CCS (ex: OPTIMEDIT\svc_certify)"

Enable-IISCentralCertProvider `
    -CertStoreLocation "\API-REST\CCSStore" `
    -UserName $readCred.UserName `
    -Password $readCred.Password `
    -PrivateKeyPassword (Read-Host -AsSecureString "Mot de passe privé CCS")
```

### 3. Configuration des liaisons IIS (Bindings HTTPS)
1. Supprimer l'ancien binding HTTPS non-SNI lié à l'ancien script PowerShell.
2. Créer un nouveau binding HTTPS avec les paramètres suivants :
   - **Type :** `https`
   - **Port :** `443`
   - **Nom d'hôte :** `api-rest.optimedit.eu`
   - **Exiger l'indication de nom du serveur (SNI) :** ☑ Coché (`SslFlags = 1`)
   - **Utiliser le magasin des certificats centralisés :** ☑ Coché (`SslFlags = 2`, ce qui combiné donne le code `3`).

> ℹ️ **Comportement normal :** Le champ *"Certificat SSL"* est grisé et vide dans l'interface IIS dès que l'option CCS est active, car le certificat n'est plus du tout stocké dans le magasin local Windows, mais lu à la volée depuis le partage UNC.

---

## 🔍 Étape 4 : Validation et Diagnostic Post-Migration

### Script de vérification multi-serveurs (`Test-CCS-Multi-Serveurs.ps1`)
Exécutez ce script de contrôle pour valider simultanément la configuration IIS interne et la restitution TLS réseau :

```powershell
$servers = @("SRV-WEB-02", "SRV-WEB-03")
$expectedThumbprint = "EC843D938E4C97486636AABC609EDD1F333555B3"

Write-Host "`n== 1. Vérification de la SOURCE du certificat (binding IIS) ==" -ForegroundColor Cyan
foreach ($srv in $servers) {
    Invoke-Command -ComputerName $srv -ScriptBlock {
        $binding = Get-WebBinding -Name "Default Web Site" -Protocol https
        $ccs = Get-IISCentralCertProvider
        $sourceCCS = ($binding.sslFlags -band 2) -ne 0 -and [string]::IsNullOrEmpty($binding.certificateHash)
        
        [PSCustomObject]@{
            Serveur        = $env:COMPUTERNAME
            BindingInfo    = $binding.bindingInformation
            SslFlags       = $binding.sslFlags
            CertHashLocal  = if ($binding.certificateHash) { $binding.certificateHash } else { "(vide)" }
            CCS_Enabled    = $ccs.Enabled
            SourceReelle   = if ($sourceCCS) { "☑ CCS" } else { "⚠️ Magasin local (pas CCS)" }
        }
    }
}

Write-Host "`n== 2. Vérification du certificat RÉELLEMENT présenté (TLS réseau) ==" -ForegroundColor Cyan
$url = "https://api-rest.optimedit.eu"
try {
    $request = [System.Net.HttpWebRequest]::Create($url)
    $request.ServerCertificateValidationCallback = { $true }
    $request.GetResponse() | Out-Null
    $thumb = $request.ServicePoint.Certificate.GetCertHashString()
    $match = if ($thumb -eq $expectedThumbprint) { "☑ Conforme" } else { "❌ DIFFÉRENT" }
    
    [PSCustomObject]@{
        URL        = $url
        Thumbprint = $thumb
        Statut     = $match
    }
} catch {
    Write-Host "Échec sur $url : $($_.Exception.Message)" -ForegroundColor Red
}
```

### 🧮 Comprendre les drapeaux `SslFlags` d'IIS
La propriété `SslFlags` est un masque de bits combinable :
- `0` = Aucun (Binding classique avec certificat dans le magasin local)
- `1` = Sni (Indication du nom du serveur activée)
- `2` = CentralCertStore (Magasin centralisé CCS activé)
- **`3`** = **Sni (1) + CentralCertStore (2)** ➔ **La valeur cible attendue et validée.**

---

## 🗑️ Étape 5 : Nettoyage Final

Une fois les tests validés (logs du Hub OK, flag `SslFlags = 3` sur tous les backends, et test TLS réseau conforme) :

1. **Désactiver puis supprimer** l'ancienne tâche PowerShell `Deploy-cert-to-backends-pwsh` dans le Certify Management Hub (`Managed Certificate → Tasks → Delete`).
2. **Supprimer le fichier du script obsolète** sur le serveur :
   ```powershell
   Remove-Item "C:\CertifyScripts\pwsh\deploy-cert-to-backends-pwsh-7.ps1" -Force
   ```

---

## 🛰️ Référence API REST du Hub (Postman)

Pour inspecter la configuration de la tâche CCS directement via l'API du Hub :

* **Endpoint :** `GET {{hub_api_url}}/internal/v1/certificate/{{instanceId}}/settings/{{managedCertId}}`
* **Extrait JSON du provider actif :**
  ```json
  {
    "id": "0152593d-ce25-4099-8336-78612-8965da",
    "taskTypeId": "Certify.Providers.DeploymentTasks.CCS",
    "taskName": "Deploy-to-CCS",
    "lastResult": "Task Completed OK",
    "lastRunStatus": 3,
    "parameters": [
      {
        "key": "path",
        "value": "\\API-REST\CCSStore"
      }
    ]
  }
  ```

---

<div align="center">

## 🏁 Résumé

**Migration CCS validée et industrialisée**
**Certify Management Hub** · **Centralized Certificate Store (UNC)** · **IIS SNI SslFlags = 3**
Plus aucun script de distribution personnalisé n'est nécessaire sur l'infrastructure.

</div>
