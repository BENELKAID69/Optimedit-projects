Les dossiers de PKI ADCS ont été déplacés vers les projets PKI dans `01.PKI-Entreprise` :

`/projets_optimedit/PKI/01.PKI-Entreprise/ADCS/`

**Lien GitHub :** [Optimedit-projects/PKI/01.PKI-Entreprise/ADCS](https://github.com/BENELKAID69/Optimedit-projects/tree/main/PKI/01.PKI-Entreprise/ADCS)

<details>
<summary><b>Pour voir l'arborescence (cliquer ici)</b></summary>

```text
├── 01.PKI-Entreprise
│   └── ADCS
│       │   ├── 03.install ADCS - Partie CA (1).png
│       │   ├── 2025-12-31_19h01_28.png
│       │   ├── CAPolicy.inf
│       │   ├── CAPolicy.inf.V1
│       │   ├── CAPolicy.pdf
│       │   └── CAPolicy-UltraSecurise.inf
│       ├── 02.Gen-Cert
│       │   ├── iis
│       │   │   ├── 01.Meth-WC-PFX-CA
│       │   │   │   ├── 01.Methode-cert-iis-WC-PFX-CA3.docx
│       │   │   │   ├── 01.Methode-cert-iis-WC-PFX-CA3.pdf
│       │   │   │   ├── Alonger dur cert CA a 3 ans.md
│       │   │   │   ├── Application-IIS-Certificat-WC.cer
│       │   │   │   ├── Application-IIS-Certificat-WC.inf
│       │   │   │   ├── Application-IIS-Certificat-WC.pfx
│       │   │   │   ├── Application-IIS-Certificat-WC.req
│       │   │   │   ├── Application-IIS-Certificat-WC.rsp
│       │   │   │   └── Create-IIS-SAN-Certificat-V3-Ok-WC.ps1
│       │   │   ├── 02.Meth-WC-FQDN-PFX
│       │   │   │   ├── Alonger dur cert CA a 3 ans.md
│       │   │   │   ├── Create-IIS-SAN-Certificat.ps1
│       │   │   │   ├── Create-IIS-SAN-Certificat-V2.ps1
│       │   │   │   ├── Create-IIS-SAN-Certificat-V3-Ok-WC.ps1
│       │   │   │   ├── IIS-SAN-Certificat.cer
│       │   │   │   ├── IIS-SAN-Certificat.inf
│       │   │   │   ├── IIS-SAN-Certificat.pfx
│       │   │   │   ├── IIS-SAN-Certificat.req
│       │   │   │   ├── IIS-SAN-Certificat.rsp
│       │   │   │   └── IIS-SAN-Certificat-V1.inf
│       │   │   ├── 03.Meth-No-WC-No-PFX-Auto-Enroll
│       │   │   │   ├── Create-Cert-no-wc-auto-enrolement.ps1
│       │   │   │   └── deux methodes.md
│       │   │   └── Modele-Test
│       │   │       ├── Modele-iis-wc-et-fqdn-no-aut-enroll (1).png
│       │   └── winrm
│       │       ├── 01.Meth-HOSTNAME-CredSSP-auto
│       │       │   ├── 01.InstallWinRM-HOSTNAME-Optimedit.ps1
│       │       │   └── ConfigureRemotingForAnsible(NET).ps1
│       │       ├── 02.Meth-WILDCARD-CA
│       │       │   ├── 02.ConfigureWinRM-Optimedit-CA.ps1
│       │       │   ├── 02.InstallWinRM-Optimedit-CA.ps1
│       │       │   ├── 2026-06-02_13h00_41.png
│       │       │   ├── 2026-06-02_13h00_42.png
│       │       │   ├── Cert-WC
│       │       │   │   ├── Alonger dur cert CA a 3 ans.md
│       │       │   │   ├── Cert-WC.cer
│       │       │   │   ├── Cert-WC.inf
│       │       │   │   ├── Cert-WC.pfx
│       │       │   │   ├── Cert-WC.req
│       │       │   │   ├── Cert-WC.rsp
│       │       │   │   └── Gen-Cert-WC.ps1
│       │       │   ├── Conf - cert - modele WC PFX.txt
│       │       │   └── Thumbprintècert-wc.txt
│       │       ├── 03.Meth-FQDN-CA--pref
│       │       │   ├── 03.Audit-WinRM-Certs.ps1
│       │       │   ├── Analyse
│       │       │   │   └── Analyse.txt
│       │       │   ├── Cert WinRM pour DC
│       │       │   │   ├── 01.Autoriser DC sur le modele de certificat.png
│       │       │   │   ├── 02.Autoriser DC sur le modele de certificat.png
│       │       │   │   ├── 03.Autoriser DC sur le modele de certificat.png
│       │       │   │   ├── 03.InstallWinRM-FQDN-CA-Optimedit-DC.ps1
│       │       │   │   ├── 04.Autoriser DC sur le modele de certificat.png
│       │       │   │   ├── 2026-05-21_20h05_02.png
│       │       │   │   ├── 2026-05-21_20h07_41.png
│       │       │   │   └── 2026-05-21_20h33_36.png
│       │       │   ├── Conf modele SAN FQDN non PFX.txt
│       │       │   ├── Template-cert-non-PFX-AutoEnroll
│       │       │   │   └── Get-Infos-Template-RDS.ps1
│       │       │   ├── Test certificat expiré.png
│       │       │   ├── V5.1
│       │       │   │   ├── 03.ConfigureWinRM-FQDN-CA-Optimedit-V5.1.ps1
│       │       │   │   └── 03.InstallWinRM-FQDN-CA-Optimedit-V5.1.ps1
│       │       │   ├── V5.2
│       │       │   │   ├── 03.ConfigureWinRM-FQDN-CA-Optimedit-V5.2.ps1
│       │       │   │   └── 03.InstallWinRM-FQDN-CA-Optimedit-V5.2.ps1
│       │       │   ├── V6.1- V. group
│       │       │   │   ├── 03.ConfigureWinRM-FQDN-CA-Optimedit-V5.2.ps1
│       │       │   │   ├── 03.InstallWinRM-FQDN-CA-Optimedit-V6.3.V-Gr.ps1
│       │       │   │   └── 03.InstallWinRM-FQDN-CA-Optimedit-V6.4.V-DC-Gr.ps1
│       │       │   └── V.OLD
│       │       │       ├── 03.ConfigureWinRM-FQDN-CA-Optimedit-V5-BK.ps1
│       │       │       ├── 03.ConfigureWinRM-FQDN-CA-Optimedit-V5.ps1
│       │       │       ├── 03.InstallWinRM-FQDN-CA-Optimedit---BK.ps1
│       │       │       └── 03.InstallWinRM-FQDN-CA-Optimedit.ps1
│       │       ├── AD ADCS
│       │       │   ├── 01.Politique d'Inscription.png
│       │       │   ├── 02.Politique d'Inscription.png
│       │       │   ├── 03.Politique d'Inscription.png
│       │       │   ├── CaName.ps1
│       │       │   └── Get-Infos-Template.ps1
│       │       ├── Certificat Ansible-WinRM-Auto-Enrollment .docx
│       │       ├── Certificat Ansible-WinRM-Auto-Enrollment .pdf
│       │       ├── Creation modele de certificat FQDN WinRM.docx
│       │       ├── Creer-modeles-de-certificat-WinRM-et-IIS.docx
│       │       ├── Creer-modeles-de-certificat-WinRM-et-IIS.pdf
│       │       ├── WinRM-Debug
│       │       │   ├── 01.Debug-WinRM-Certificate-Stack-Remote.ps1
│       │       │   ├── 02.Debug-WinRM-Certificate-Stack-Remote.ps1
│       │       │   ├── 03.Debug-WinRM-Certificate-Stack-Remote.ps1
│       │       │   ├── 04.Debug-WinRM-Certificate-Stack-Remote.ps1
│       │       │   ├── Debug-WinRM-Certificate-Stack.ps1
│       │       │   ├── Debug-WinRM-Certificate-Stack-Remote.ps1
│       │       │   └── Debug-WinRM-Certificate-Stack-V2.ps1
│       │       └── WinRM-Debug-cert
│       │           ├── Audit-WinRM-Certs.ps1
│       │           └── Audit-WinRM-Certs-v3.sh
│       └── 03.Ex-Import-CA3-To-Ansible
│           ├── 03.Export-Import-Cert-CA3-To-Ansible.yml
│           ├── Exempl_execution.png
│           ├── Exempl_execution.txt
│           ├── install_and_test_cert_ca.sh
│           └── Optimedit-CA3.cer
├── 02.PKI-Publique
│   └── Certify Hub
│       ├── 01.ACME-HTTP-01
│       │   ├── 01.Solution-Scripts-PS
│       │   │   ├── API-Request-Postman
│       │   │   │   ├── Request-API.txt
│       │   │   │   ├── response-01.Get-DeploymentProviders.json
│       │   │   │   ├── response-02.Test-configuration-Powershell-v5.1.json
│       │   │   │   ├── response-02.Test-configuration-pwsh-7.json
│       │   │   │   └── response-03.Post-Test-configuration.json
│       │   │   ├── CertifyScripts---Deploy
│       │   │   │   ├── PowerShell-pwsh-v7
│       │   │   │   │   ├── export
│       │   │   │   │   │   └── latest.pfx
│       │   │   │   │   ├── logs_pwsh
│       │   │   │   │   │   ├── deploy_20260721_201135-log-script.log
│       │   │   │   │   │   └── View-log-Hub.txt
│       │   │   │   │   ├── README-Certify-PS7-Task.md
│       │   │   │   │   ├── scripts_pwsh
│       │   │   │   │   │   ├── deploy-cert-to-backends-pwsh-7.ps1
│       │   │   │   │   │   └── regenerate-secrets-pwsh-7.ps1
│       │   │   │   │   └── secure_pwsh
│       │   │   │   │       ├── aes.key
│       │   │   │   │       ├── deploy-pwd.enc
│       │   │   │   │       └── pfx-pwd.enc
│       │   │   │   └── PowerShell-v5.1
│       │   │   │       ├── export
│       │   │   │       │   └── latest.pfx
│       │   │   │       ├── logs
│       │   │   │       │   ├── deploy_20260717_203828.log
│       │   │   │       │   └── View_log_hub.log
│       │   │   │       ├── README-Certify-PS5.1-Task.md
│       │   │   │       ├── scripts
│       │   │   │       │   ├── 01.Gen_AES-Key.ps1
│       │   │   │       │   ├── 02.ConvertTo-SecureString-aes.ps1
│       │   │   │       │   ├── 03.secure-enc-file.ps1
│       │   │   │       │   └── deploy-cert-to-backends.ps1
│       │   │   │       └── secure
│       │   │   │           ├── aes.key
│       │   │   │           ├── deploy-pwd.enc
│       │   │   │           └── pfx-pwd.enc
│       │   │   ├── Certify-Task-PowerShell.docx
│       │   │   ├── Certify-Task-PowerShell.pdf
│       │   │   ├── Scripts-Validations
│       │   │   │   ├── Get-thumbprint.ps1
│       │   │   │   └── Test-URLs.ps1
│       │   │   └── Zabbix-regle.docx
│       │   └── 02.Solution-CCS-Natif
│       │       ├── CCSStore
│       │       │   └── api-rest.optimedit.eu.pfx
│       │       ├── logs
│       │       │   ├── (1-log avec pwsh task)f9712ad8-bd49-430c-8cff-370633369e53.log
│       │       │   └── (2-log sans pwsh task)f9712ad8-bd49-430c-8cff-370633369e53.log
│       │       ├── README-Certify-CCS-Task.docx
│       │       ├── README-Certify-CCS-Task.md
│       │       ├── README-Certify-CCS-Task.pdf
│       │       └── Test-ccs-multi-serveurs.ps1
│       ├── Exposition Certify Management Hub Port 8443.docx
│       └── Exposition Certify Management Hub Port 8443.pdf
├── 03.PKI-Hybride
│   ├── architecture_hybride.xlsx
│   ├── Procedure_Certify_Hub_Optimedit_V3.docx
│   ├── Procedure_Certify_Hub_Optimedit_V4.docx
│   └── Procedure_Certify_Hub_Optimedit_V4.pdf
└── architectures_docs
    └── architecture_pki_chiffrement_https_2_cas.pdf

48 directories, 199 files