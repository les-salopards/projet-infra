# Déploiement sur la VM Énov

La VM fait tourner **les mêmes images et le même `compose.yml`** que le poste de dev. Seuls le `.env` et les noms d'hôte changent.
Les images Rallly custom sont construites par la CI et publiées sur GHCR : la VM ne fait que `pull`.

## 1. Accès à la plateforme Énov (une fois par personne)
Source : [documentation publique Énov](https://github.com/Enov-Salle-Serveur/Documentation_Public/blob/main/README.md).

| Étape | Où | À retenir |
| --- | --- | --- |
| Compte | [enov.icu](https://enov.icu) | Adresse **@ynov.com**, code de vérification reçu par mail. |
| VPN | [netbird.enov.icu:4443](https://netbird.enov.icu:4443/) (la doc affiche aussi `netbird.enov.vaultaire.fr:4443`) → *Sign in with Keycloak* | Mêmes identifiants qu'enov.icu. Installer le client NetBird (`brew install netbirdio/tap/netbird` sur macOS) et l'activer. |
| Clé SSH | [nebula.cloud.enov.local:2616](http://nebula.cloud.enov.local:2616) → profil → *Settings* → *Add SSH Key* | Le domaine `.enov.local` ne résout **que VPN actif**. Clé : `ssh-keygen -t ed25519`, coller le `.pub`. **Avant** de créer la VM, sinon pas d'accès. |
| VM | Nebula → *Template* → le seul template → *Instantiate* | Nom : `projet-infra`. Prévoir **4 vCPU / 8 Go RAM** (Authentik + Rallly + 2 Postgres). *Advanced* → *Network* → *Attach NIC* → le seul réseau. |
| Connexion | `ssh root@<IP>` | L'IP s'affiche dans l'onglet des instances. |

Les réglages MTU 1450 de la doc Énov ne concernent qu'un LAN personnel : **ne pas les appliquer** ici.

## 2. Préparer la VM (une fois)
```sh
# depuis un clone local du dépôt, VPN actif
ssh root@<IP> 'bash -s' < deploy/bootstrap-vm.sh
ssh deploy@<IP> true          # vérifier que la clé fonctionne pour deploy
ssh root@<IP> 'LOCK_ROOT=1 bash -s' < deploy/bootstrap-vm.sh   # puis couper le login root
```
`bootstrap-vm.sh` est idempotent (testé deux fois de suite sur Ubuntu 24.04) :
- installe Docker Engine et le plugin Compose depuis le dépôt officiel ;
- crée l'utilisateur `deploy` (groupe docker) avec les clés SSH de root ;
- configure le pare-feu (22, 80, 443) et SSH par clé uniquement ;
- active les mises à jour de sécurité automatiques ;
- configure le démon Docker : `no-new-privileges` par défaut et rotation des logs ;
- clone le dépôt dans `/opt/projet-infra`.

## 3. Déployer / mettre à jour
```sh
ssh deploy@<IP>
cd /opt/projet-infra
cp .env.example .env && nano .env    # 1re fois : secrets + DOMAIN (voir §4)
./deploy/deploy.sh
```
`deploy.sh` enchaîne : `git pull` → `docker compose config` → `pull` → `up -d --wait` → smoke tests
(discovery OIDC d'Authentik, `/api/status` de Rallly) → liste des ports publiés (attendu : 80 et 443 seulement).

## 4. Écarts local / VM
| Élément | Local | VM | Pourquoi |
| --- | --- | --- | --- |
| `DOMAIN` | `localhost` (`auth.localhost`, `rallly.localhost`) | `<IP-avec-tirets>.sslip.io` (ex. `10-0-12-34.sslip.io`) | La VM n'a pas de DNS public. sslip.io renvoie l'IP privée contenue dans le nom, joignable via NetBird, sans fichier hosts. |
| Redirect URI Authentik | `https://rallly.localhost/api/auth/callback/oidc` | `https://rallly.<DOMAIN>/api/auth/callback/oidc` | Doit correspondre exactement à `NEXT_PUBLIC_BASE_URL` ; à mettre à jour dans le provider Authentik. |
| Images Rallly | build local possible | `ghcr.io/les-salopards/rallly:<tag>` | La VM ne build jamais : elle déploie ce que la CI a testé et scanné. |
| Secrets | `.env` local | `.env` sur la VM (`chmod 600`) | Jamais dans Git ; chaque environnement a les siens. |
| TLS | `tls internal` (CA Caddy) | identique | Pas de Let's Encrypt possible sans IP publique. Le formateur doit accepter le certificat ou importer la CA Caddy. |

## 5. Accès formateur
- VPN NetBird Énov actif, puis `https://rallly.<DOMAIN>` et `https://auth.<DOMAIN>`.
- Comptes de démo : voir la doc Authentik (Raph).
- En secours : partage d'écran depuis un poste de l'équipe connecté au VPN.

## 6. Déploiement depuis la CI
La VM n'est joignable que via le VPN : un runner GitHub hébergé ne peut pas s'y connecter en SSH.
Choix retenu : **la CI publie l'image sur GHCR, puis on lance `deploy.sh` sur la VM** (déploiement documenté, déclenché à la main).
Option si le temps le permet : un runner GitHub self-hosted installé sur la VM, avec un job `deploy` limité à `main`.

## Pièges rencontrés
- **sshd par socket (Ubuntu 24.04)** : `/run/sshd` n'existe pas tant qu'aucune connexion n'a eu lieu, donc `sshd -t` échoue. Le script crée le dossier.
- **`start-limit-hit` de Docker** : des `systemctl restart docker` en rafale bloquent le service. Le script ne redémarre que si `daemon.json` change.
- **Docker contourne ufw** : un port publié par Docker est ouvert même si ufw l'interdit. La vraie protection, c'est de ne publier que 80/443 dans le Compose.
