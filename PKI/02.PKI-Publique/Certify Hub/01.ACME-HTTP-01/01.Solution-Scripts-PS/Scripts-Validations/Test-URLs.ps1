# Définition des URLs à tester
$urls = @(
    "http://api-rest.optimedit.eu",
    "https://api-rest.optimedit.eu"
)

# Test de chaque URL
foreach ($url in $urls) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
        [PSCustomObject]@{
            URL          = $url
            Statut       = $response.StatusCode
            Description  = $response.StatusDescription
            Accessible   = $true
        }
    }
    catch {
        [PSCustomObject]@{
            URL          = $url
            Statut       = $_.Exception.Response.StatusCode.value__
            Description  = $_.Exception.Message
            Accessible   = $false
        }
    }
}


#Invoke-WebRequest : Envoie une requête HTTP/HTTPS vers l'URL spécifiée.

# -UseBasicParsing : Évite d'utiliser Internet Explorer pour analyser le contenu (recommandé et obligatoire sous PowerShell 5.1 sur les serveurs Core).

# Bloc try/catch : Permet de capturer les erreurs (par exemple, si le port 80/443 est bloqué, si le certificat SSL n'est pas approuvé, ou si le site renvoie un code d'erreur type 400 ou 500) sans interrompre le script.