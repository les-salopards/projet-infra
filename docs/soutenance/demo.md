# Soutenance : déroulé de la démo

15 min de présentation + démo, 3 min de questions. Support : [slides.md](slides.md) (Marp :
`npx @marp-team/marp-cli docs/soutenance/slides.md --pdf --html --allow-local-files`, ou l'extension VS Code « Marp »).

## La veille (sur la VM, VPN actif)
- [ ] `ssh deploy@<IP> 'cd /opt/projet-infra && ./deploy/deploy.sh'` → « Déploiement OK », ports 80/443 seulement
- [ ] Package GHCR `rallly` **public** (sinon la VM ne peut pas tirer l'image)
- [ ] `RALLLY_IMAGE=ghcr.io/les-salopards/rallly:latest` dans le `.env` de la VM (image du fork avec les 3 features)
- [ ] CA de Caddy importée dans le navigateur de démo (sinon avertissement à chaque page) : voir [docs/vm.md](../vm.md#5-accès-formateur)
- [ ] Les 3 comptes se connectent : `alice` OK, `bob` OK, `charlie` refusé
- [x] Sondages de démo préparés **par `alice`** : un ouvert, et « Séminaire » réservé au groupe `rallly-users`
  (VM du 18/11 : « Réunion d'équipe » `/invite/7tcBVGU9BkQv`, « Séminaire » `/invite/OpgLFitygRyW`)
  (pas par `bob` : un organisateur passe outre la règle de groupe, il ne pourrait pas servir de contre-exemple)
- [ ] Sondage **horaire** pour la #7, créé par `bob`, sur deux mois, avec un jour à 4 créneaux ; `alice` n'y a pas répondu
- [ ] Mailpit vidé (`https://mail.<DOMAIN>`)
- [x] Capture du pipeline vert sur `main` insérée dans les slides (`docs/img/ci-fork-main-vert.png`)
- [ ] `./scripts/scan.sh` relancé : chiffres de la slide « Scan commenté » à jour
- [ ] Répétition complète chronométrée, chacun sa partie

## Le jour même : onglets ouverts à l'avance
1. `https://rallly.<DOMAIN>` en navigation privée (invité)
2. `https://rallly.<DOMAIN>` connecté en `alice` (autre profil de navigateur)
3. `https://auth.<DOMAIN>` connecté en `bob` (admin)
4. `https://mail.<DOMAIN>`
5. GitHub : onglet Actions du fork (run vert) et Packages (image GHCR)
6. Terminal SSH sur la VM : `docker compose ps`

## Déroulé
| Temps | Qui | Slide / démo | Ce qu'on montre |
| --- | --- | --- | --- |
| 0:00 | César | Titre, livré, architecture | Schéma : Caddy seul exposé, réseaux internal, URL publique pour l'OIDC |
| 2:30 | Raph | Authentik | **Démo 1** : `alice` se connecte (SSO) ; `charlie` → *Permission denied* ; `bob` crée une invitation → lien → inscription → l'e-mail arrive dans Mailpit |
| 5:30 | Eliott | Local et VM | Terminal VM : `docker compose ps`, même `compose.yml` ; seul `.env` diffère |
| 6:30 | César | CI/CD | Run vert sur `main` du fork (lint, tests, build, push, scan), image dans GHCR |
| 7:30 | Raph puis Eliott | Features | **Démo 2** : invité → lecture seule, requête rejouée → `loginRequired` ; `alice` vote sous son identité IdP ; sondage réservé (créé par `alice`) : `bob` refusé (« votre compte n'en fait pas partie »), le compte invité à la démo 1 (groupe `rallly-users`) vote |
| 10:30 | César | Catalogue #7 | **Démo 3** : `alice` sur le sondage horaire → Calendrier → vote dans la grille, « +1 autres », mois suivant → retour au Tableau avant d'enregistrer (votes présents) → Continuer |
| 12:00 | Eliott | Durcissement, scan, limites | Tableau vérifié dans les conteneurs ; CRITICAL de la stack 7 → 2 (acceptées, expirent), image du fork 3 → 0 |
| 14:30 | tous | Questions | |

## Si quelque chose casse
| Symptôme | Réaction immédiate |
| --- | --- |
| Pas de bouton « Authentik » sur Rallly | `docker compose restart rallly` (discovery OIDC ratée au démarrage) |
| `rallly.<DOMAIN>` ne résout pas | VPN NetBird actif ? Sinon ligne dans `/etc/hosts` (voir [docs/vm.md](../vm.md#pièges-rencontrés)) |
| VM injoignable | Basculer sur la stack locale d'un poste (`DOMAIN=localhost`, même image) : même démo |
| Invitation : pas d'e-mail | Le lien est aussi copiable depuis Admin → Annuaire → Invitations |
| Après connexion, le bandeau dit encore « Connectez-vous pour répondre » | Recharger la page (F5) : elle n'est pas rafraîchie au retour d'Authentik |
| *Déconnexion* dans Rallly, mais on revient connecté sous le même compte | La session Authentik est toujours ouverte : se déconnecter aussi sur `https://auth.<DOMAIN>/flows/-/default/invalidation/`, ou changer de profil de navigateur (un compte par profil, comme prévu ci-dessus) |

## Questions probables
- *Rallly a déjà une vue calendrier ?* Seulement sur une page expérimentale et pour les journées entières ; la nôtre est
  sur la vraie page de vote, gère les créneaux horaires et partage le formulaire du tableau (aucun nouveau chemin serveur).
- *Pourquoi Caddy ?* TLS automatique (CA interne ici), config de 15 lignes, un bloc par application.
- *Pourquoi l'URL publique d'Authentik depuis Rallly ?* L'issuer du jeton doit être identique pour le navigateur et pour Rallly.
- *Comment prouvez-vous le refus côté serveur ?* Requête rejouée hors interface → `loginRequired` / `notMember`.
- *Que se passe-t-il si une CVE critique apparaît ?* Le scan hebdomadaire passe au rouge ; on monte de version ou on
  justifie dans `.trivyignore.yaml` (limité au paquet), avec une date d'expiration.
- *Pourquoi pas Let's Encrypt ?* Pas d'IP publique ni de DNS public sur la VM Énov.
