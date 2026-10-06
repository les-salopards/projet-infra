# Feature libre — Sondage réservé à un groupe Authentik

Porteur : La Tribe · Branche du fork : `feat/group-restricted-poll` · Dépend de : claim `groups` (Raph), feature #1 (fonction « peut voter ? »).

## Problème
Un sondage Rallly est ouvert à toute personne qui a le lien. Dans une organisation, on veut souvent
limiter un vote à une équipe (ex. « date du séminaire des admins ») sans gérer une liste d'e-mails à la main.
L'annuaire existe déjà : ce sont les groupes Authentik.

## Ce que fait la feature
- Le créateur saisit un **nom de groupe Authentik** dans les réglages du sondage (création ou édition).
  Champ vide = sondage ouvert à tous, comme avant.
- Seuls les utilisateurs **connectés via OIDC** et **membres de ce groupe** peuvent répondre ou modifier leur réponse.
- Les autres voient le sondage en lecture seule, avec un bandeau :
  - invité ou compte sans identité OIDC → « réservé au groupe X, connectez-vous » + bouton de connexion ;
  - compte OIDC hors du groupe → « votre compte n'en fait pas partie ».
- Les organisateurs du sondage gardent l'accès complet.

## Fonctionnement
| Étape | Où | Détail |
| --- | --- | --- |
| Groupes de l'utilisateur | Authentik → Rallly | Le scope `profile` d'Authentik envoie le claim `groups` dans l'ID token. Better Auth stocke l'ID token dans `accounts.id_token` à chaque connexion. |
| Lecture | `features/poll/group-access/data.ts` | Décodage du payload de l'ID token stocké, chemin du claim configurable via `OIDC_GROUPS_CLAIM_PATH` (défaut `groups`). |
| Règle | `features/poll/group-access/utils.ts` | `open` / `allowed` / `loginRequired` / `notMember`, fonction pure testée (11 tests Vitest). |
| Refus serveur | `features/poll/participant/actions.ts` | `addParticipantAction` et `updateParticipantVotesAction` refusent avec `reason: "loginRequired" \| "notMember"`. Un lien d'édition reçu par e-mail ne contourne pas la règle. |
| UI | `invite-page.tsx`, `poll-settings.tsx` | Bandeau `GroupRestrictionBanner`, formulaire masqué via `usePermissions`, champ « Réserver à un groupe ». |
| Données | migration `20261006120000_add_poll_allowed_group` | Colonne `polls.allowed_group TEXT NULL` : aucun sondage existant n'est modifié. |

Pas de colonne ajoutée sur `users` : les groupes sont relus depuis l'ID token, donc rafraîchis à chaque connexion sans
écraser le nom ou l'avatar que l'utilisateur a pu modifier dans Rallly.

## Limites assumées
- Les groupes sont figés jusqu'à la **prochaine connexion** : retirer quelqu'un d'un groupe dans Authentik ne
  lui retire l'accès qu'après reconnexion (ou expiration de sa session Rallly).
- Le nom du groupe est saisi à la main (pas de liste déroulante : Rallly n'interroge pas l'API Authentik).
- Un seul groupe par sondage.
- Les commentaires ne sont pas restreints (ils sont désactivés par défaut dans Rallly).

## Intégration avec la #1 (Raph)
La #1 verrouille le vote derrière une session OIDC. La règle de groupe est isolée dans `getPollGroupAccess()` :
quand la fonction serveur commune « peut voter ? » de la #1 est mergée, elle appelle cette fonction
et les deux contrôles des actions de vote fusionnent en un seul appel.

## Scénario de démo (2 min)
Comptes Authentik : `alice` (groupe `rallly-users`), `bob` (groupe `rallly-admins` uniquement).
1. Le créateur crée un sondage, « Réserver à un groupe » = `rallly-users`.
2. Navigation privée, lien du sondage → bandeau « connectez-vous », pas de formulaire.
3. Connexion SSO en `bob` → bandeau rouge « votre compte n'en fait pas partie ».
4. Connexion SSO en `alice` → vote enregistré.
5. Preuve côté serveur : rejouer l'action de vote de `bob` (DevTools → requête copiée) → refus `notMember`.
