# 🌐 Optimedit - Dépôt Central des Projets et PoCs d'Infrastructure

[![Company](https://img.shields.io/badge/Company-Optimedit.eu-blueviolet?style=flat-square)](https://optimedit.eu)
[![Infrastructure](https://img.shields.io/badge/Scope-Infrastructure%20&%20PoCs-0078D6?style=flat-square&logo=windows&logoColor=white)](https://github.com/BENELKAID69/Optimedit-projects)
[![Security](https://img.shields.io/badge/Confidentiality-Strict%20Internal%20%2F%20Validation-success?style=flat-square&logo=security&logoColor=white)](https://optimedit.eu)

Ce dépôt Git centralise l'ensemble des environnements de validation, des **Proof of Concepts (PoCs)** et des documentations techniques d'infrastructure développés pour **Optimedit** et ses projets professionnels.

> **Note de Confidentialité :** Seuls les éléments techniques, les scripts d'automatisation et les documentations de validation/laboratoire sont partagés ici. Les données, configurations et environnements spécifiques aux clients d'Optimedit font l'objet d'une stricte confidentialité et ne sont en aucun cas divulgués sur GitHub.

---

## 🏗️ Structure & Organisation des Projets

L'infrastructure globale se compose de multiples projets modulaires. Chaque sous-dossier de projet dispose de son propre fichier `README.md` et de ses procédures d'installation dédiées.

Voici un aperçu des principaux modules et documentations référencés dans ce dépôt :

| Domaine / Composant | Intitulé & Description | Accès Direct au README |
| :--- | :--- | :--- |
| **🚀 Ansible & IIS** | Infrastructure as Code & Automatisation IIS pour le domaine `optimedit.eu`. | [Voir le README](https://github.com/BENELKAID69/Optimedit-projects/blob/main/iis_infras/infra_iis_cert_wc_ansible_v.2.14.18/00.00.infra_iis_cert_wc_ansible.README.md) |
| **🔐 PKI (PowerShell 5.1)** | CertifyScripts — Automatisation de certificats sécurisée (AES + PowerShell 5.1). | [Voir le README](https://github.com/BENELKAID69/Optimedit-projects/blob/main/PKI/02.PKI-Publique/Certify%20Hub/01.ACME-HTTP-01/01.Solution-Scripts-PS/CertifyScripts---Deploy/PowerShell-v5.1/README-Certify-PS5.1-Task.md) |
| **🔐 PKI (PowerShell 7)** | CertifyScripts — Automatisation de certificats cross-plateforme (PowerShell 7+). | [Voir le README](https://github.com/BENELKAID69/Optimedit-projects/blob/main/PKI/02.PKI-Publique/Certify%20Hub/01.ACME-HTTP-01/01.Solution-Scripts-PS/CertifyScripts---Deploy/PowerShell-pwsh-v7/README-Certify-PS7-Task.md) |
| **🗄️ PKI (CCS Natif)** | CertifyHub — Migration et gestion vers le Centralized Certificate Store (CCS). | [Voir le README](https://github.com/BENELKAID69/Optimedit-projects/blob/main/PKI/02.PKI-Publique/Certify%20Hub/01.ACME-HTTP-01/02.Solution-CCS-Natif/README-Certify-CCS-Task.md) |

---

## 📋 Navigation Rapide

Pour explorer un projet spécifique, veuillez naviguer directement dans l'arborescence du dépôt racine :
* `/iis_infras/` : Déploiements web, serveurs IIS et automatisations Ansible associées.
* `/PKI/` : Autorités de certification, gestion des certificats SSL/TLS et scripts de renouvellement ACME.

---
*Documentation globale gérée par **Driss Benelkaid** — [Optimedit.eu](https://optimedit.eu)*