# Vue calendrier pour répondre (#7) — plan d'implémentation

> **Pour l'exécutant :** exécution native dans la session (superpowers:executing-plans), tâche par tâche, cases à cocher.

**But :** une bascule Tableau / Calendrier sur `/invite/[urlId]` ; la vue calendrier permet de répondre et écrit dans le même `VotingForm` que le tableau.

**Architecture :** un dossier `features/poll/components/calendar-poll/` dans le fork : des fonctions pures testées
(`utils.ts`), une grille mensuelle maison (pas de `MonthGrid`, dont chaque jour est un `<button>`), des cellules de jour
avec des boutons de créneau, et des contrôles de réponse qui réutilisent `useVotingForm`. `ResponsiveResults` porte la
bascule. Aucun changement serveur.

**Stack :** Next.js / React, react-hook-form, Tailwind, `@rallly/ui`, Vitest (jsdom, `TZ=Asia/Kathmandu`), Biome.

**Spec :** `projet-infra/docs/specs/calendar-vote-view.md`. Code : fork `rallly`, branche `feat/calendar-vote-view` depuis `main`.

## Contraintes globales
- Le tableau reste la vue par défaut ; `DesktopPoll`, `MobilePoll` et les actions serveur ne sont pas modifiés.
- Un seul état de vote : `useVotingForm()` (`votes[]` aligné sur `poll.options`, `mode` `view`/`new`/`edit`).
- Jour d'un créneau : journée entière → date UTC ; créneau horaire → date dans `poll.timeZone ? fuseau du visiteur : "UTC"`
  (même règle que `createOptionsContextValue`).
- Cellule : 3 créneaux visibles au plus, puis « +N autres ».
- Textes en `en` et `fr` (`apps/web/public/locales/{en,fr}/app.json`), via `t(key, { defaultValue })`.
- Commits en anglais, style gitmoji du fork, sans trailer `Co-Authored-By`.
- Avant PR : `pnpm turbo check`, `pnpm check:locales`, `pnpm type-check`, `pnpm --filter @rallly/web test:unit` verts.

## Points de vigilance (non couverts par une tâche seule)
1. Bascule Calendrier → Tableau en cours de réponse : les votes déjà cliqués restent (test manuel, tâche 5).
2. Sondage dont toutes les options sont passées : le calendrier s'ouvre sur le mois de la première option (test tâche 1).
3. `allowTentativeVotes = false` : le clic ne propose jamais « si besoin » (test tâche 2, via `toggleVote`).
4. Créneau à 23 h 30 UTC vu depuis Paris : rangé le lendemain (test tâche 1).
5. Sondage sans option : pas de bascule, tableau seul (tâche 3).

---

### Tâche 1 : fonctions pures

**Fichiers :**
- Créer : `apps/web/src/features/poll/components/calendar-poll/utils.ts`
- Test : `apps/web/src/features/poll/components/calendar-poll/utils.test.ts`

**Interfaces produites :**
- `groupOptionsByDay(options: { id: string; startTime: Date; duration: number }[], zones: { pollTimeZone: string | null; viewerTimeZone: string }): Map<string, string[]>` — clé `YYYY-MM-DD`, valeur : ids des options de ce jour, dans l'ordre de `startTime`. S'appuie sur `getCalendarDate` (`@/lib/datetime/utils`).
- `getInitialMonth(days: string[], today: string): string` — `YYYY-MM` du premier jour `>= today`, sinon du premier jour ; `today` si `days` est vide.
- `getMonthWeeks(month: string, weekStartsOn: 0 | 1): (string | null)[][]` — semaines du mois (`YYYY-MM-DD`), `null` pour les cases hors mois.
- `shiftMonth(month: string, delta: number): string`.
- `splitVisible<T>(items: T[], max?: number): { visible: T[]; hidden: number }` — `max` vaut 3 par défaut.

- [ ] **Étape 1 : écrire les tests** (`describe` par fonction)
  - `groupOptionsByDay` : journée entière `2026-11-24T00:00Z` (durée 0) → `2026-11-24` quel que soit le fuseau ;
    créneau `2026-11-24T23:30Z` (60 min), `pollTimeZone: "Europe/Paris"`, `viewerTimeZone: "Europe/Paris"` → `2026-11-25` ;
    même créneau, `pollTimeZone: null` → `2026-11-24` ; trois créneaux du même jour donnés dans le désordre → ids triés par heure.
  - `getInitialMonth(["2026-10-02", "2026-11-20", "2026-12-03"], "2026-11-18")` → `"2026-11"` ;
    `getInitialMonth(["2026-10-02"], "2026-11-18")` → `"2026-10"` ; `getInitialMonth([], "2026-11-18")` → `"2026-11"`.
  - `getMonthWeeks("2026-11", 1)` : 6 semaines, première `[null ×6, "2026-11-01"]`, dernière commence par `"2026-11-30"` ;
    `getMonthWeeks("2026-11", 0)` : première semaine commence par `"2026-11-01"`.
  - `shiftMonth("2026-12", 1)` → `"2027-01"` ; `shiftMonth("2026-01", -1)` → `"2025-12"`.
  - `splitVisible([1,2,3,4,5])` → `{ visible: [1,2,3], hidden: 2 }` ; `splitVisible([1,2])` → `{ visible: [1,2], hidden: 0 }`.
- [ ] **Étape 2 :** `pnpm --filter @rallly/web exec vitest run src/features/poll/components/calendar-poll` → échec (module absent).
- [ ] **Étape 3 :** implémenter `utils.ts` (arithmétique de dates en UTC sur des chaînes `YYYY-MM-DD`, aucune dépendance au fuseau du processus).
- [ ] **Étape 4 :** même commande → vert.
- [ ] **Étape 5 :** commit `✨ Add calendar grouping helpers for the calendar vote view`.

### Tâche 2 : grille et cellules (consultation + clic de vote)

**Fichiers :**
- Créer : `calendar-poll/calendar-poll.tsx` (en-tête mois + navigation + grille), `calendar-poll/calendar-day.tsx` (cellule),
  `calendar-poll/calendar-slot.tsx` (bouton d'un créneau)
- Test : `calendar-poll/calendar-slot.test.tsx`

**Interfaces :**
- Consomme : tâche 1 ; `usePoll()` (`poll.options`, `poll.timeZone`, `poll.allowTentativeVotes`, `getScore`), `useOptions()` (libellés horaires par `optionId`), `useVotingForm()`, `toggleVote` (`vote-selector.tsx`), `VoteIcon`, `useDateTimeConfig()` (`timeZone`, `locale`), `getLocaleDefaults(locale)` pour le premier jour de la semaine (comme `vote-view-calendar.tsx`).
- Produit : `export function CalendarPoll(): JSX.Element` ; `CalendarSlot` props `{ label: string | null; score: number; vote?: VoteType; editable: boolean; allowTentativeVotes: boolean; onChange: (vote: VoteType) => void }`.

- [ ] **Étape 1 : test `CalendarSlot`** (Testing Library) : `editable`, `vote: "yes"`, `allowTentativeVotes: true` → clic appelle `onChange("ifNeedBe")` ; `allowTentativeVotes: false` → `onChange("no")` ; `editable: false` → bouton désactivé, aucun appel ; affiche le score.
- [ ] **Étape 2 :** lancer le test → échec.
- [ ] **Étape 3 :** implémenter `CalendarSlot`, `CalendarDay`, `CalendarPoll` :
  - l'index de l'option dans `poll.options` donne le champ `votes.${index}.type` du formulaire (`watch` pour lire, `setValue` pour écrire) ;
  - éditable si `mode !== "view"` ; en `view`, l'icône montre le vote du participant du visiteur (`participants.find(p => p.userId === user.id)` via `useUser`) ;
  - cellule : jours sans option grisés ; journée entière = un seul `CalendarSlot` sans libellé qui occupe la cellule ;
    « +N autres » ouvre un `Popover` (`@rallly/ui/popover`) qui liste tous les créneaux du jour ;
  - mois initial : `getInitialMonth` avec `getCalendarDate(new Date(), timeZone)` ; boutons précédent / suivant (`shiftMonth`).
- [ ] **Étape 4 :** test vert ; `pnpm type-check` vert.
- [ ] **Étape 5 :** commit `✨ Render poll options in a month grid that records votes`.

### Tâche 3 : bascule Tableau / Calendrier et contrôles de réponse

**Fichiers :**
- Modifier : `apps/web/src/features/poll/components/responsive-results.tsx`
- Créer : `calendar-poll/calendar-response-controls.tsx`
- Modifier : `apps/web/public/locales/en/app.json`, `apps/web/public/locales/fr/app.json`

**Interfaces :**
- Consomme : `CalendarPoll` (tâche 2), `VotingFooter` (`voting-footer.tsx`), `useVotingForm().setEditingParticipantId` / `cancel`.
- Produit : `ResponsiveResults` garde un état `view: "table" | "calendar"` (défaut `"table"`) ; bascule rendue seulement si `poll.options.length > 0`.

- [ ] **Étape 1 :** bascule (deux boutons `@rallly/ui/button`, `aria-pressed`) au-dessus du contenu de `PollOutcome` ; en `calendar`, rendre `CalendarPoll` à la place de `DesktopPoll` / `MobilePoll`.
- [ ] **Étape 2 :** `CalendarResponseControls` sous la grille : `mode = new` → `<VotingFooter />` ; `mode = view` et le visiteur a une réponse → bouton « Modifier ma réponse » → `setEditingParticipantId(id)` ; `mode = edit` → Enregistrer (`type="submit"`, soumet le `VotingForm` englobant) + Annuler (`cancel()`).
- [ ] **Étape 3 :** clés i18n `calendarViewTable` (« Tableau » / « Table »), `calendarViewCalendar` (« Calendrier » / « Calendar »), `calendarMoreOptions` (« +{count} autres » / « +{count} more »), `calendarEditResponse` (« Modifier ma réponse » / « Edit my response »), `calendarPreviousMonth`, `calendarNextMonth`. `pnpm check:locales` vert.
- [ ] **Étape 4 :** `pnpm type-check`, `pnpm turbo check` verts.
- [ ] **Étape 5 :** commit `✨ Let participants answer a poll from a calendar view`.

### Tâche 4 : mobile

**Fichiers :** modifier `calendar-poll/calendar-poll.tsx` (ou créer `calendar-poll/calendar-poll-compact.tsx`).

- [ ] **Étape 1 :** sous 640 px (même `createBreakpoint` que `ResponsiveResults`) : grille compacte, un point sous les jours qui ont des options ; un appui sélectionne le jour et liste ses `CalendarSlot` en dessous ; en-tête minimal (bascule déjà au-dessus, `TimesShownIn`) ; mêmes `CalendarResponseControls`.
- [ ] **Étape 2 :** `pnpm type-check`, `pnpm turbo check` verts.
- [ ] **Étape 3 :** commit `📱 Add a compact calendar view for small screens`.

### Tâche 5 : vérification, PR, image

- [ ] **Étape 1 :** Rallly en dev (`pnpm dev`, Postgres jetable) : sondage horaire sur deux mois, dont un jour à 4 créneaux ; dérouler le scénario de démo de la spec (étapes 1 à 5) dans un vrai navigateur, ordinateur puis 390 px. Points de vigilance 1, 3 et 5 vérifiés à la main.
- [ ] **Étape 2 :** `pnpm turbo check`, `pnpm check:locales`, `pnpm type-check`, `pnpm --filter @rallly/web test:unit` verts.
- [ ] **Étape 3 :** PR `feat/calendar-vote-view` → `main` du fork ; CI `Image` verte ; merge (admin).
- [ ] **Étape 4 :** stack `projet-infra` avec `RALLLY_IMAGE=ghcr.io/les-salopards/rallly:latest` : scénario rejoué avec `alice` via Authentik ; captures dans `projet-infra/docs/img/`, ligne #7 dans le tableau Features du README, spec mise à jour (« Vérifié »).
