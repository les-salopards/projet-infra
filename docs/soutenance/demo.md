# Soutenance : déroulé de la démo

15 min de présentation + démo, 3 min de questions. Support : [slides.md](slides.md) (Marp :
`npx @marp-team/marp-cli docs/soutenance/slides.md --pdf --allow-local-files`, ou l'extension VS Code « Marp »).

## La veille (sur la VM, VPN actif)
- [ ] `ssh deploy@<IP> 'cd /opt/projet-infra && ./deploy/deploy.sh'` → « Déploiement OK », ports 80/443 seulement
- [ ] `RALLLY_IMAGE` du `.env` de la VM = le tag publié par la CI (image du fork avec les features)
- [ ] CA de Caddy importée dans le navigateur de démo (sinon avertissement à chaque page) : voir [docs/vm.md](../vm.md#5-accès-formateur)
- [ ] Les 3 comptes se connectent : `alice` OK, `bob` OK, `charlie` refusé
- [ ] Sondage de démo préparé (créé par `bob`) : « Séminaire » réservé au groupe `rallly-users`, et un sondage ouvert
- [ ] Mailpit vidé (`https://mail.<DOMAIN>`)
- [ ] Capture du pipeline vert sur `main` insérée dans les slides
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
| 6:30 | porteur CI | CI/CD | Run vert sur `main`, image dans GHCR |
| 7:30 | Raph puis Eliott | Features | **Démo 2** : invité → lecture seule, requête rejouée → `loginRequired` ; `alice` vote sous son identité IdP ; sondage réservé : `bob` refusé (« votre compte n'en fait pas partie »), `alice` vote |
| 11:30 | Eliott | Durcissement, scan, limites | Tableau vérifié dans les conteneurs ; 7 → 2 CRITICAL, risques acceptés qui expirent |
| 14:30 | tous | Questions | |

## Si quelque chose casse
| Symptôme | Réaction immédiate |
| --- | --- |
| Pas de bouton « Authentik » sur Rallly | `docker compose restart rallly` (discovery OIDC ratée au démarrage) |
| `rallly.<DOMAIN>` ne résout pas | VPN NetBird actif ? Sinon ligne dans `/etc/hosts` (voir [docs/vm.md](../vm.md#pièges-rencontrés)) |
| VM injoignable | Basculer sur la stack locale d'un poste (`DOMAIN=localhost`, même image) : même démo |
| Invitation : pas d'e-mail | Le lien est aussi copiable depuis Admin → Annuaire → Invitations |

## Questions probables
- *Pourquoi Caddy ?* TLS automatique (CA interne ici), config de 15 lignes, un bloc par application.
- *Pourquoi l'URL publique d'Authentik depuis Rallly ?* L'issuer du jeton doit être identique pour le navigateur et pour Rallly.
- *Comment prouvez-vous le refus côté serveur ?* Requête rejouée hors interface → `loginRequired` / `notMember`.
- *Que se passe-t-il si une CVE critique apparaît ?* Le scan hebdomadaire passe au rouge ; on monte de version ou on
  justifie dans `.trivyignore`, avec une date d'expiration.
- *Pourquoi pas Let's Encrypt ?* Pas d'IP publique ni de DNS public sur la VM Énov.
