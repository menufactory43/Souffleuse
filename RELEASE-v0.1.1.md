# Souffleuse (llama.cpp fork) — v0.1.1

Jalon « pertinence ». v0.1.0 avait un ghost rapide mais qui « ne trouvait pas
les bons mots ». v0.1.1 corrige le cœur de la pertinence + une cascade de bugs
de qualité du ghost, fondé sur des expériences mesurées au probe.

## Pertinence du ghost (le gros morceau)
- **Profil anti-junk au sampler** (greedy, donc cache KV déterministe) :
  - `banMarkup` : le modèle base (pt) crachait du `<strong>`/`<code>` (web) → banni à la source.
  - `banDigitsLeading` : tuait le prior « texte web » (« Des » → « 20 ans », « 2019 ») sur le 1ᵉʳ token, sans perdre les chiffres légitimes ensuite.
  - `banEmoji` + strip du parasite U+FFFD.
  - rep penalty 1.3 contre les boucles.
  - → « 2017 du Festival » devient « de transport sont à la charge du client », « erreur de syntaxe », « fruits, des légumes et de la viande ».
- **Ponctuation gardée** (parité Cotypist) : plus de coupe au premier `, ` → ghosts naturels et complets (« de manger, je crois », « rguez ? »).

## Robustesse de la personnalisation
- **Biais corpus robuste au bruit** : nucleus gate (ne booste qu'un token déjà plausible) + match ≥ 2 tokens + count ≥ 2. Une base partiellement polluée ne peut plus injecter de junk (« meufs ») — vérifié sur 20 prompts.
- **Filtre fragment à l'entrée** : rejette la résidu de live-consume (« s de ») sans toucher au vocabulaire rare de l'utilisateur.
- **Toggle « enregistrer sans acceptation »** (parité Cotypist) : enregistre le contenu des champs même sans acceptation, pour un dataset de style plus riche. Mesuré utile (matchLen 7 vs 0 pour les fragments seuls).

## Bugs de ghost corrigés
- **« envies de »** : un ghost mid-mot périmé n'est plus consommé bêtement (re-prédiction).
- **moignon « m »** : plus de ghost d'une seule lettre en début de mot.
- Continuations après un mot complet, apostrophe/trait d'union, effacement du périmé sur divergence.

## Garde-fous
- macOS 14+ Apple Silicon. Aucun réseau au runtime, corpus chiffré (SQLCipher).
- `audit.sh` vert (6/6). 357 tests (échecs résiduels = timing flaky sous charge parallèle, verts en isolé).

## Limitations connues
- Le choix de mot « signature » (style Cotypist « merguez ») dépend de la personnalisation : la base doit s'enrichir de tes acceptations / inputs. Un mot perso inhabituel reste difficile à imposer à un modèle 1B sans corpus.
- Apparition du ghost : latence + stabilité de position en cours d'affinage.
