# Note de cadrage — Projet Dev avec Docker

6 oct. 2026 · César Victor. Copie de la note d'origine (l'artefact en ligne n'est plus accessible). État au 18/11 en fin de page.

## Contexte et objectifs
L'infra passe en premier : sans stack stable, les features ne compensent pas la note pratique. Le module « Dev avec
Docker » (M2 FullStack Ynov, 28 h, formateur Florian Guillemard) se termine par une soutenance de 15 min de démo + 3 min
de questions.
- **Équipe** : César, Raph, La Tribe.
- **Objectif** : un environnement local + VM Énov avec reverse proxy, Authentik (OIDC) devant Rallly, une CI/CD verte et
  3 features Rallly (2 du catalogue + 1 libre).
- **Notation** : N_groupe = 0,60 × pratique + 0,40 × restitution. La pratique valorise surtout l'infra (image, Compose,
  durcissement, CI).
- **Bonus** : +1 point par feature mergée ou validée upstream par le mainteneur de Rallly.

## Périmètre
Le sujet impose des capacités, pas une stack : le choix du proxy, de la CI et du TLS nous revient.

| Bloc | Attendu minimum | Preuve en soutenance |
| --- | --- | --- |
| Compose local | Stack reproductible : clone + README + compose up ; secrets dans `.env` gitignoré, `.env.example` commité ; non-root + scan commenté | Démarrage depuis un clone propre |
| Reverse proxy | Point d'entrée unique vers Authentik et Rallly ; BDD jamais exposée | Schéma réseau + ports ouverts |
| Authentik | SSO OIDC vers Rallly ; 2 groupes aux droits distincts ; invitation d'un externe | Démo des 3 parcours |
| VM Énov | Déploiement cohérent avec le local, écarts documentés, accès formateur | URL + comptes de test |
| CI/CD | Build des images (idéalement tests + scan), pipeline verte sur main, déploiement ou publication documenté | Run vert sur GitHub Actions |
| Features | 2 catalogue + 1 libre, démontrables | Démo live + captures dans le README |

Livrables : dépôt public (Compose, Dockerfiles, workflows, README, schéma d'architecture, comptes de démo, doc Authentik,
features), support de présentation, démo live. Tous les membres présentent.

## Features retenues
Liste de vœux au formateur : #7 et #1, avec la #12 en repli (le catalogue est attribué par lui).

| Feature | Origine | Difficulté | Pourquoi | Pièges principaux |
| --- | --- | --- | --- | --- |
| #7 Vue calendrier pour répondre (#2419, #167) | Catalogue | Difficile | La plus visuelle en démo ; surtout de l'UI, sans changer le modèle de données | Grille mensuelle multi-mois et mobile ; fuseaux horaires ; réutiliser l'état de vote existant |
| #1 Vote verrouillé par OAuth (#177, #1294) | Catalogue | Moyenne, transverse | Relie l'infra Authentik au code Rallly | Bloquer les invités sur tous les chemins de vote ; redirect URI derrière le proxy |
| Sondage réservé à un groupe Authentik | Libre | Moyenne | Réutilise les policies par groupe de l'infra | Claim `groups` ; groupes figés jusqu'à la reconnexion ; refus côté serveur ; dépend de la #1 |
| #12 Analyse des résultats (#320, #284) | Repli catalogue | Moyenne | Visuelle et isolée | Rester lisible avec beaucoup d'options |

Bonus upstream peu probable : très peu de PR externes acceptées par Rallly. Piste si on tente : un petit bug ouvert comme
#1677 (créneaux passés).

## Dépôts et workflow Git
- **Fork `rallly`** : uniquement le code des features ; une branche `feat/<nom>` par feature, PR vers `main` avec
  relecture et CI verte. Le code devient une image publiée sur GHCR, tirée par le même Compose en local et sur la VM.
- **`projet-infra`** : Compose, proxy, Authentik, `.env.example`, workflows, README, schéma, `docs/specs/`.
- PR upstream uniquement depuis une branche partie d'`upstream/main`, sans fichier propre à notre projet.

## Répartition des rôles
| Personne | Pilier infra | Feature |
| --- | --- | --- |
| César | Création des dépôts, Compose local, reverse proxy, CI/CD (build, scan, push GHCR) | #7 Vue calendrier |
| Raph | Authentik : SSO OIDC, policies par groupe, invitation externe, doc | #1 Vote verrouillé par OAuth |
| La Tribe | VM Énov (NetBird, SSH, déploiement), durcissement (non-root, scan commenté) | Sondage réservé à un groupe |

Rôle transverse de César : specs des features, relecture des PR, garant du README.

## Jalons
1. Séance 1 : orga GitHub, fork, `projet-infra`, protection de `main`, Rallly en dev pour chacun.
2. **J1** Compose local démarrable (César).
3. **J2** SSO Authentik → Rallly, puis policies et invitation (Raph).
4. **J3** Stack déployée sur la VM Énov (La Tribe).
5. **J4** CI verte sur `main` : build, scan, publication de l'image Rallly custom (César).
6. Features en parallèle ; gel une semaine avant la soutenance, puis comptes de démo, support et répétition.

## Risques et parades
| Risque | Impact | Parade |
| --- | --- | --- |
| OIDC instable | Bloque SSO, #1 et feature libre | J2 prioritaire ; pièges notés au fil de l'eau |
| #7 trop lourde | Feature inachevée | Vue mensuelle d'abord, puis la réponse ; repli #12 |
| Accès VM / NetBird en retard | Pas de démo cloud | Créer compte et VM dès la séance 1 |
| Catalogue attribué différemment | Répartition à revoir | Garder les binômes, échanger les features |
| Divergence fork / upstream | Conflits | Petites PR |
| Secrets commités | Faille | `.env` gitignoré, scan de secrets en CI |

## État au 18/11/2026 (veille de la soutenance)
| Bloc | État |
| --- | --- |
| Compose local, proxy, Authentik (J1, J2) | Fait (stack de Raph, PR #2) |
| Durcissement, scan, doc VM, slides (La Tribe) | Fait (PR #3), CI `security-scan` verte |
| CI/CD du fork (J4) | Fait : lint, tests, build, push GHCR, scan, vert sur `main` |
| #1, feature libre, #7 | Mergées dans le fork, dans l'image `latest` |
| VM Énov (J3) | Fait : `10.2.192.14`, image du fork `sha-d805601`, SSO et policies vérifiés depuis le VPN (PR #6) |
