---
name: alexandrie
description: Créer, mettre à jour, lister et supprimer des documents et des fichiers dans une instance Alexandrie auto-hébergée, via son API. Utiliser ce skill dès que l'utilisateur demande d'écrire, publier, téléverser ou récupérer quelque chose dans Alexandrie, sa base de connaissances ou son wiki — y compris « mets ça dans Alexandrie », « crée une note », « publie ce compte rendu », « envoie ce PDF ». Ne pas utiliser pour installer, sauvegarder ou mettre à jour la stack : cela relève du Makefile à la racine du dépôt.
---

# Piloter Alexandrie par son API

Le script `alx`, à côté de ce fichier, fait tout. **Il se lance depuis la racine
du dépôt Alexandrie** (il lit le `.env` pour connaître le domaine).

```bash
.claude/skills/alexandrie/alx login          # une fois, la session est gardée
.claude/skills/alexandrie/alx doc-create note.md --nom "Compte rendu"
.claude/skills/alexandrie/alx upload schema.pdf
.claude/skills/alexandrie/alx ls
```

`alx aide` liste les commandes.

## Le piège qui justifie ce skill

**Le backend ne compile pas le markdown.** Il stocke deux champs séparés :
`content` (la source) et `content_compiled` (le HTML). Les vues de lecture
affichent littéralement `v-html="node.content_compiled"`, **sans repli** sur la
source.

Un document créé par un simple `curl` sur `POST /api/nodes` avec le seul `content`
**s'affiche donc blanc**. La donnée est en base, l'écran est vide, et rien
n'explique pourquoi. Vérifié :

```
name                     md   html
Note de recette          66   0      ← créé par curl : illisible
Document par le skill    72   486    ← créé par alx : s'affiche
```

`alx` appelle **le compilateur d'Alexandrie, dans le conteneur du frontend**, qui
embarque déjà markdown-it et les dix-huit greffons maison (conteneurs, KaTeX,
Mermaid, couleurs, cases à cocher, liens internes, ancres). Rien n'est
réimplémenté, rien ne dérive : mettre à jour Alexandrie met à jour le compilateur
du même geste.

**Ne jamais créer un document en appelant l'API à la main.** Passer par
`alx doc-create`, ou fournir soi-même `content_compiled` obtenu par
`alx compile`.

## Ce que l'API demande, et qui ne s'invente pas

| | |
|---|---|
| **Authentification** | **cookie uniquement**. Pas de `Bearer`, pas de jeton d'API. `alx login` garde la session dans `.session` (chmod 600, ignoré par git). Elle expire : au premier **401**, relancer `login` |
| **`role`** | `1` workspace, `2` dossier, `3` document, `4` fichier téléversé. Tout est dans la même table `nodes` |
| **`accessibility`** | **obligatoire**, `NOT NULL` sans défaut. L'omettre rend un **500** « Column 'accessibility' cannot be null ». `1` = privé, **`3` = publié en lecture libre** |
| **`name`** | 50 caractères maximum. Au-delà, un 400 qui parle de validation sans dire laquelle. `alx` tronque |
| **Téléversement** | multipart, champ `file`. L'URL publique est `<CDN_URL>/<bucket>/<userId>/<transformed_path>` — le `userId` **ne figure pas** dans la réponse, il faut le composer. `alx upload` rend l'URL complète |

## Publier un document en lecture libre

`accessibility = 3`, et **rien d'autre**. Le commentaire du modèle amont
(`node.model.go`) annonce `0: Public; 1: Private; 2: Unlisted` — **il est faux** :
la requête qui sert les documents publics filtre sur `accessibility = 3`.

```sql
WHERE n.id = ? AND EXISTS (SELECT 1 FROM ancestors WHERE accessibility = 3)
```

Avec `0`, l'API rend `{"result": null}` et la page publique affiche
« Unknown document » — sans jamais dire que le problème vient de là.

L'accès est **hérité** : publier un dossier (`role` 2) publie toute sa descendance.

L'URL est `https://<domaine>/doc/<identifiant>`. Il n'existe **pas** de champ
`slug` : l'identifiant snowflake est la seule adresse. Pour une URL lisible, la
seule voie propre est une redirection au niveau du reverse proxy.

Le référencement dépend d'une chose qui ne se voit pas : le conteneur du frontend
doit pouvoir joindre l'API **par son nom public** pour son rendu serveur. Si cet
appel échoue, la page répond quand même 200, mais vide — titre « Unknown
document », pas une ligne du document dans le HTML. Le navigateur, lui, refait
l'appel côté client et affiche tout : la panne est invisible à l'œil et totale
pour un moteur de recherche. Le `docker-compose.yml` traite ce cas (`extra_hosts`
sur le frontend) ; vérifier après tout changement d'infrastructure :

```bash
curl -s https://<domaine>/doc/<id> | grep -o '<title>[^<]*</title>'
```

## Trois choses à savoir avant de s'en servir

**Les fichiers téléversés sont publics.** Le bucket porte une politique
`s3:GetObject` pour tout le monde : l'URL rendue par `alx upload` s'ouvre sans
authentification. Seule l'imprévisibilité de l'identifiant protège le fichier. Ne
pas y déposer de document sensible en croyant qu'il suit les droits du document
qui le référence.

**Les liens internes ne se résolvent pas.** Le compilateur prend en second
argument un résolveur qui traduit un identifiant en titre ; le navigateur
l'alimente depuis son cache, `alx` ne l'a pas. Un `[[lien]]` s'affichera par son
identifiant. Sans conséquence pour du texte ordinaire.

**La stack doit tourner.** La compilation se fait dans le conteneur du frontend :
`make start` si `alx` s'en plaint.

## Si `alx compile` échoue

Le bundle de Nuxt est minifié : le fichier porte un hachage et la fonction un nom
d'une lettre, et les deux changent à chaque version de l'amont. `alx` ne code rien
en dur — il cherche le module au motif `markdown-*.mjs`, puis essaie chaque export
jusqu'à en trouver un qui transforme du markdown en HTML.

Si le message dit « aucun export ne se comporte comme compile() », l'amont a
réorganisé son bundle : il faut aller voir `/app/.output/server/chunks/build` dans
le conteneur et adapter la sonde. C'est le seul point fragile du dispositif, et il
échoue bruyamment plutôt qu'en silence.

## Ce qui n'est pas ici

Installer, sauvegarder, restaurer, mettre à jour la stack : c'est le `Makefile` à
la racine (`make`, sans argument, liste tout). Ce skill ne touche qu'au contenu.
