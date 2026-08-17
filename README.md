# Alexandrie — auto-hébergement

Ce dépôt n'est **pas** l'application. C'est le nécessaire pour héberger
[Alexandrie](https://github.com/Smaug6739/Alexandrie) — une base de connaissances
en Markdown, auto-hébergeable — chez soi ou sur un serveur : le `docker-compose.yml`
branché sur un reverse proxy Traefik, une sauvegarde chiffrée vers
[borgwarehouse](https://github.com/CoopCodeCommun/borgwarehouse), et un `Makefile`
qui rend tout cela exécutable.

L'application elle-même vient de ses images publiées ; rien n'est recompilé ici.

```bash
make install        # tout : le .env, le réseau, les conteneurs
make backup         # la sauvegarde (elle se configure toute seule au 1er lancement)
make backup-check   # la répétition générale : éteindre, restaurer, vérifier
make update         # mettre à jour, et vérifier que ça tient
make                # la liste complète
```

---

## Sommaire

- [Ce qu'il faut avant de commencer](#ce-quil-faut-avant-de-commencer)
- [Installation](#installation)
- [Le premier compte](#le-premier-compte-à-faire-tout-de-suite)
- [Les commandes de tous les jours](#les-commandes-de-tous-les-jours)
- [La sauvegarde](#la-sauvegarde)
- [La mise à jour](#la-mise-à-jour)
- [Tout remonter après un sinistre](#tout-remonter-après-un-sinistre)
- [Comment c'est branché, et pourquoi](#comment-cest-branché-et-pourquoi)
- [Quand ça ne marche pas](#quand-ça-ne-marche-pas)

---

## Ce qu'il faut avant de commencer

**Sur la machine :** `docker` (avec le plugin `compose`), et — pour la sauvegarde
seulement — `borg`, `openssl`, `curl`, `crontab`, `flock`. Ils sont tous dans les
dépôts d'une Debian ou d'une Ubuntu :

```bash
sudo apt install docker.io docker-compose-v2 borgbackup openssh-client \
                 openssl curl cron util-linux
```

`openssh-client` n'est pas optionnel : la sauvegarde génère une clé dédiée avec
`ssh-keygen` et parle au dépôt par `ssh`. Sur une Debian minimale, il manque.

**Un Traefik qui tourne déjà**, sur un réseau Docker nommé `frontend`. C'est lui qui
termine le HTTPS et route les trois noms de domaine. Celui de
[TraefikV3](https://github.com/CoopCodeCommun/TraefikV3) convient tel quel.
`make install` crée le réseau s'il manque, mais pas le proxy.

**Trois noms qui pointent sur la machine.** Alexandrie a besoin de trois hôtes —
voir [pourquoi](#comment-cest-branché-et-pourquoi) :

| Nom | Ce qu'il sert |
|---|---|
| `alexandrie.exemple.fr` | le site |
| `api.alexandrie.exemple.fr` | l'API |
| `cdn.alexandrie.exemple.fr` | les fichiers téléversés |

Trois enregistrements `A`, ou un joker `*.alexandrie.exemple.fr`. Sur un poste de
développement, rien à faire : `*.localhost` résout tout seul.

---

## Installation

```bash
git clone <ce dépôt> Alexandrie
cd Alexandrie
make install
```

`make install` pose **quatre questions, dont deux se sautent d'une touche** :

1. poste de développement ou production ?
2. le domaine du site ?
3. l'adresse de votre serveur de sauvegarde borgwarehouse — *facultatif*,
   `make backup` la redemandera le moment venu ;
4. un serveur SMTP — *facultatif*, il ne sert qu'au lien « mot de passe oublié ».

Les deux dernières sont posées ici plutôt que codées en dur : l'adresse d'un
serveur de sauvegarde désigne **votre** infrastructure, elle n'a rien à faire dans
un fichier versionné sur une forge publique.

Puis il fait le reste :

- il écrit le `.env` en **tirant tous les secrets au hasard** (clé JWT, mots de
  passe MySQL, clés S3). Aucun secret n'est saisi à la main : une clé tapée au
  clavier est une clé faible, ou recopiée d'un autre projet ;
- il en déduit les trois URLs et le domaine du cookie, **d'un seul bloc** ;
- il crée le réseau `frontend` s'il manque ;
- il démarre les quatre conteneurs et **attend qu'ils répondent vraiment**.

C'est **idempotent** : relancer `make install` ne régénère pas le `.env` et ne
casse rien. C'est la commande à retaper après avoir modifié une variable.

> **Le `.env` est la seule copie du mot de passe de la base.** Il n'est pas dans
> git, et rien ne le régénère. Sur une machine de production, le mettre au coffre.

---

## Le premier compte, à faire tout de suite

Aucun compte n'existe au démarrage, et **l'inscription est ouverte à tous**.

> **S'inscrire en premier ne donne aucun privilège.** Alexandrie n'a pas de notion
> de « propriétaire » : le premier compte est un compte comme un autre, et le
> statut d'administrateur vient **uniquement** de `ADMIN_ACCOUNTS`. S'arrêter à
> « je me suis inscrit le premier » laisse une instance dont personne n'est admin.

Sur une machine joignable de l'extérieur, faire les trois d'affilée :

```bash
# 1. s'inscrire sur https://<votre domaine>/
# 2. relever son identifiant numérique (page de profil)
# 3. dans le .env :
ADMIN_ACCOUNTS=744213485931593729     # cet identifiant
CONFIG_DISABLE_SIGNUP=true            # ferme la porte derrière soi

make install    # applique les deux
```

Entre l'installation et l'étape 3, n'importe qui connaissant l'URL peut créer un
compte. C'est la seule vraie fenêtre de risque de toute l'installation.

---

## Les commandes de tous les jours

| Commande | Ce qu'elle fait |
|---|---|
| `make` | la liste des cibles |
| `make install` | tout installer, ou appliquer un changement du `.env` |
| `make status` | l'état des quatre conteneurs |
| `make logs` | suivre les journaux (`make logs S=backend` pour un seul) |
| `make stop` / `make start` | arrêter, redémarrer (les données restent) |
| `make backup` | sauvegarder |
| `make verif-archive` | la dernière archive est-elle restaurable ? (ne touche à rien) |
| `make backup-check` | la répétition générale (**éteint le site**) |
| `make update` | mettre à jour et vérifier |
| `make restore` | recharger une archive (**écrase les données**) |

---

## La sauvegarde

```bash
make backup
```

Une seule commande, et c'est voulu. Au premier lancement sur une machine, rien
n'est configuré : `make backup` enchaîne alors lui-même sur la configuration —
clé SSH dédiée, création du dépôt sur borgwarehouse **via son API**, tirage d'une
passphrase, `borg init`, mise au coffre, cron — puis sauvegarde et vérifie. Les
fois suivantes, il sauvegarde directement.

Il n'y a donc **pas** de commande d'initialisation à retenir. Une commande qu'on
ne tape qu'une fois dans la vie d'une machine est une commande qu'on ne retrouve
pas le jour où on en a besoin.

Deux choses vous seront demandées :

- **un jeton API borgwarehouse** (*Account → Integrations*), avec la permission
  **`create` seule** : c'est le seul appel que fait le script. Sans jeton, il
  affiche la clé publique et vous laisse créer le dépôt à la main ;
- **de confirmer que la passphrase est au coffre.** Ce n'est pas une formalité :
  voir juste en dessous.

### Ce qu'il y a dans une archive

| | Pourquoi |
|---|---|
| le dump MySQL | comptes, documents, arborescence, permissions |
| le contenu du stockage S3 | images, PDF, pièces jointes — hors base, irremplaçables |
| le `.env` | clé JWT, mots de passe, clés S3 |

Le reste est dans git ou dans les images publiées. Les réarchiver chaque nuit
n'apporterait rien qu'un `git clone` ne rende déjà.

### Le coffre-fort

À la configuration, le script affiche **quatre éléments d'un seul bloc**, à copier
tels quels dans un coffre-fort numérique :

1. les quatre lignes du `.env` : `BORG_PREFIX`, `BORG_REPO`, `BORG_PASSPHRASE`
   **et `AGE_MAX_HEURES`** — oublier la quatrième fait repartir une machine qui
   sauvegardait toutes les heures avec le seuil de fraîcheur par défaut de 25 h ;
2. la **clé SSH privée** du dépôt (elle ouvre l'**accès**) ;
3. la clé de chiffrement (`borg key export`) ;
4. la recette de restauration complète.

Sans eux, les archives sont **un bloc chiffré définitivement illisible**. C'est le
seul maillon que la sauvegarde ne peut pas se sauvegarder elle-même.

### Les deux contrôles, et leur différence

```bash
make verif-archive   # ne touche à rien
make backup-check    # ÉTEINT le site et recharge la sauvegarde
```

**`make verif-archive`** répond à « est-ce restaurable ? » sans rien restaurer, en
quelques secondes, et sort en code non nul dès que quelque chose cloche : c'est
celui qui va dans un cron ou un monitoring. Il vérifie la fraîcheur de la dernière
archive, son contenu, et — le point qui compte — que le dump **n'est pas tronqué**.

> Un dump coupé en plein milieu a une taille crédible, se trouve bien dans
> l'archive, et se recharge **sans la moindre erreur** : `mysql` avale un fichier
> tronqué et sort en 0. Rien, dans le code de retour, ne distingue une base
> entière d'une base amputée de sa moitié. Le seul indice fiable est la dernière
> ligne que `mysqldump` n'écrit qu'une fois tout sorti — c'est elle qu'on cherche.

**`make backup-check`** est la répétition générale du sinistre : il met le site hors
service, sauvegarde cet état gelé, **détruit les volumes**, remonte la stack à vide,
recharge la sauvegarde, et compare tout à l'état gelé. C'est le seul contrôle qui
prouve vraiment quelque chose — une archive qu'on a lue n'est pas une archive qu'on
a rechargée.

Il **ne perd rien**, et ce n'est pas un vœu : l'archive rechargée est celle qu'il
vient de prendre.

> **La coupure commence avant la sauvegarde, et c'est ce qui rend la promesse
> vraie.** Tant que le site servait pendant l'archivage, une note saisie entre le
> dump et la destruction n'était ni dans l'archive ni dans le relevé de départ :
> elle était détruite, et le verdict ne la voyait pas manquer. Geler d'abord coûte
> quelques minutes de coupure en plus ; c'est le prix d'une promesse tenue.

Il vérifie l'archive **avant de rien détruire** : si elle cloche, il s'arrête et
remet le site en service.

Pendant la phase destructrice, il pose un marqueur qui empêche le cron de
sauvegarder — sans quoi une sauvegarde tombant pile entre le remontage à vide et la
restauration archiverait une base vide, qui deviendrait la plus récente.

À lancer à la main, une fois par trimestre, et après tout changement de la chaîne
de sauvegarde. `make backup-check CONFIRME=oui` saute la question.

---

## La mise à jour

```bash
make update
```

`docker compose pull && docker compose up -d` tient en une ligne. Cette cible
existe pour les trois choses que cette ligne ne fait pas :

1. **elle pose un filet.** Les migrations d'Alexandrie ne savent pas revenir en
   arrière : sans archive fraîche, une mise à jour ratée est définitive. Elle
   vérifie donc la sauvegarde en place, **puis en prend une neuve**, avant de tirer
   quoi que ce soit. Vérifier ne suffisait pas : l'archive de la veille est valable
   au regard du contrôle de fraîcheur, et restaurer dessus effacerait une journée
   d'écritures ;
2. **elle note d'où l'on vient.** `latest` ne dit pas quelle version tourne ; une
   fois l'image remplacée, plus rien sur la machine ne le dit. Les empreintes
   d'avant sont affichées : elles s'épinglent telles quelles pour revenir en
   arrière ;
3. **elle vérifie après.** Un conteneur `running` ne prouve rien. Elle regarde
   l'état des migrations (`dirty = 1` veut dire qu'une migration s'est arrêtée en
   plein milieu — le seul échec qui ne se voit dans aucun code HTTP), le nombre de
   lignes en base, et les trois URLs.

S'il n'y a rien de neuf, elle le dit et ne redémarre rien.

---

## Tout remonter après un sinistre

Sur une machine neuve, avec le contenu du coffre :

```bash
git clone <ce dépôt> Alexandrie && cd Alexandrie
make install                      # répondre aux deux questions

# ajouter au .env les lignes BORG_* et AGE_MAX_HEURES du coffre
mkdir -p bin/.ssh && chmod 700 bin/.ssh
# y coller la clé SSH privée SOUS SON NOM EXACT : bin/.ssh/<BORG_PREFIX>_ed25519
chmod 600 bin/.ssh/<BORG_PREFIX>_ed25519

make restore                      # les données
```

> Le **nom** du fichier de clé compte. Les scripts cherchent exactement
> `bin/.ssh/<BORG_PREFIX>_ed25519` ; une clé reposée sous un autre nom n'est
> simplement pas vue, ssh se rabat sur la configuration système, et le refus parle
> de permissions — jamais de nom de fichier.

`make restore` écrase la base et les fichiers en service : il demande une
confirmation tapée. Il **n'installe jamais** le `.env` de l'archive, il le dépose
à côté — celui en service porte la passphrase du dépôt courant, qui peut être
différente.

---

## Comment c'est branché, et pourquoi

```
                       ┌─────────┐
   :443 ─────────────► │ Traefik │  (réseau « frontend », externe à cette stack)
                       └────┬────┘
          ┌─────────────────┼──────────────────┐
          ▼                 ▼                  ▼
   alexandrie.·      api.alexandrie.·   cdn.alexandrie.·
     frontend            backend             rustfs
      (Nuxt)              (Go)             (stockage S3)
          └─────────────────┼──────────────────┘
                            ▼
                          mysql        ← ni port publié, ni étiquette Traefik
```

**Trois hôtes, pas un.** Ce découpage n'est pas un goût, c'est le seul qui marche :

- **le CDN ne peut pas vivre sous un chemin** (`/fichiers/`). La spécification S3
  interdit un chemin dans l'URL qui sert à signer ; l'amont le documente, symptôme
  « `XML syntax error on line 1` ». Il lui faut un hôte à lui ;
- **le cookie de session** doit porter le plus haut domaine **commun** au site et à
  l'API. Avec `alexandrie.·` et `api.alexandrie.·`, c'est `alexandrie.·`. Mal
  réglé, le login **réussit** puis l'utilisateur est déconnecté à la page suivante,
  sans un message nulle part.

`make install` écrit ces quatre valeurs d'un seul bloc, à partir du seul domaine :
les désynchroniser est justement ce qui casse le site sans qu'on le voie.

**MySQL n'est joignable de nulle part** : pas de port publié, pas d'étiquette
Traefik. Seuls les conteneurs du réseau interne l'atteignent.

**Les étiquettes Traefik ne fixent aucun `entrypoint`**, volontairement : le
routeur se pose sur tous ceux qui existent, et le même fichier marche derrière
n'importe quelle configuration de Traefik. Le résolveur de certificat, lui, se
règle par `CERT_RESOLVER` dans le `.env`.

**Tout se lance depuis l'hôte.** Aucune commande n'entre dans un conteneur pour y
travailler : les images de l'amont sont minimales et n'ont pas de shell. Toute la
logique vit dans `bin/`, et le `Makefile` ne fait que l'appeler — jamais la
recopier. Deux définitions d'une même séquence finissent toujours par diverger, et
une sauvegarde qui dérive ne le signale jamais.

---

## Quand ça ne marche pas

**« Je me connecte, et je suis déconnecté aussitôt. »**
`COOKIE_DOMAIN` ne couvre pas les deux hôtes. Il vaut `DOMAIN`, **sans protocole
et sans port**. Vérifier que le site et l'API sont bien sous le même domaine
parent, puis `make install`.

**« Les fichiers se téléversent mais ne s'affichent pas. »**
`CDN_URL` ou `CDN_ENDPOINT`. `CDN_URL` doit être une origine **sans chemin ni
paramètre** (`https://cdn.exemple.fr`, pas `https://exemple.fr/fichiers/`), et
`CDN_ENDPOINT` doit valoir le nom du bucket, `/alexandrie/` par défaut. Ouvrir les
outils du navigateur pour lire l'URL réellement demandée.

**« Le navigateur crie au certificat. »**
Sur un domaine en `.localhost`, c'est normal et voulu : `CERT_RESOLVER` est laissé
**vide**, et Traefik sert son certificat auto-signé. Un résolveur ACME demanderait
à Let's Encrypt un certificat pour un nom qui n'est pas public — refus immédiat,
rejoué sans fin dans les journaux. En production, `CERT_RESOLVER=myresolver`.

**« `NetworkError when attempting to fetch resource` à l'inscription »** — ou toute
requête vers l'API qui n'obtient **aucune** réponse, pas même un code HTTP.

En `.localhost`, il faut accepter l'exception de certificat sur **les trois hôtes**,
pas seulement sur le site. Accepter celle du site ne dit rien au navigateur de
`api.` ni de `cdn.` : ce sont des hôtes distincts, avec chacun leur certificat.
Une requête vers un hôte dont le certificat est refusé échoue **avant** d'avoir un
statut — d'où l'absence totale de réponse, qui ressemble à tort à un problème de
CORS ou de réseau.

Ouvrir ces deux adresses une fois, dans le même navigateur, et accepter :

```
https://api.alexandrie.localhost/api/users/public/x   → 404 en JSON, c'est la bonne réponse
https://cdn.alexandrie.localhost/alexandrie/          → du XML « AccessDenied », idem
```

Le CDN compte autant que l'API : sans son exception, le compte se crée mais aucune
image ne s'affiche. En production, avec un certificat signé, la question ne se pose
pas.

**« Le site rend 404. »**
Un 404 sur la racine vient en général de **Traefik**, pas de l'application :
aucun routeur ne correspond à ce nom. Vérifier que `DOMAIN` correspond à l'URL
demandée, et que les conteneurs sont bien sur le réseau du proxy
(`docker network inspect frontend`).

**« Le backend redémarre en boucle. »**
`make logs S=backend`. Si une migration s'est arrêtée en plein milieu, la table
`schema_migrations` porte `dirty = 1` : c'est ce que `make update` détecte, et le
seul remède propre est `make restore`.

---

## Passer en production

La bonne nouvelle d'abord : **la corvée des certificats disparaît**. En répondant
« 2 » à `make install`, `CERT_RESOLVER=myresolver` et `MINIO_INSECURE_TLS=false`
sont écrits ensemble, Traefik obtient trois certificats Let's Encrypt, et plus
personne n'a rien à accepter dans son navigateur.

Ce à quoi il faut faire attention, dans l'ordre où ça mord :

**1. Les trois noms doivent résoudre publiquement, et le 443 être ouvert.**
Le résolveur de TraefikV3 utilise le défi `tlsChallenge` (TLS-ALPN-01) : Let's
Encrypt se connecte au **port 443** de la machine, sur chacun des trois noms. Un
443 filtré, ou un nom qui ne résout pas encore, et le certificat n'arrive jamais —
Traefik sert alors son certificat par défaut, et le navigateur crie.

**2. Se tromper coûte cher, chez Let's Encrypt.** La limite est de 5 certificats
identiques par semaine. Tant que la configuration n'est pas sûre, décommenter la
ligne `caserver` de `traefik.yml` pour viser le serveur de test : les certificats
ne sont pas reconnus par les navigateurs, mais ils sont illimités. La recommenter
une fois que ça marche, puis supprimer `letsencrypt/acme.json` pour forcer une
vraie émission.

**3. Fermer l'inscription dans la minute.** Voir
[Le premier compte](#le-premier-compte-à-faire-tout-de-suite). Sur un serveur
public, c'est la seule fenêtre pendant laquelle n'importe qui peut devenir
propriétaire de l'instance.

**4. La sauvegarde vise le vrai borgwarehouse.** `make backup` demandera l'URL, le
port SSH et un jeton API — la machine doit pouvoir sortir en SSH vers ce port. Et
surtout : **copier réellement le bloc du coffre-fort**. C'est la seule étape de
toute l'installation qu'aucun script ne peut rattraper à votre place.

**5. `make backup-check` est une vraie coupure.** Il éteint le site et détruit les
volumes. Rien n'est perdu, mais le site est injoignable quelques minutes : à lancer
en connaissance de cause, pas un vendredi à 18 h. Le contrôle qui tourne tous les
jours, lui, c'est `make verif-archive`, qui ne touche à rien.

**6. CrowdSec filtre déjà tout.** Chez TraefikV3, le bouncer est posé sur
l'`entryPoint` HTTPS : il s'applique à Alexandrie sans rien à configurer. Si un
403 inexpliqué apparaît après avoir martelé l'API pendant la mise en route, c'est
peut-être vous :

```bash
docker exec -t crowdsec cscli decisions list
docker exec -t crowdsec cscli decisions delete -i <votre IP>
```

**7. Ce qui est déjà réglé, et qu'on ne verra donc pas.** La fonction d'export
d'Alexandrie fait sortir le backend vers l'adresse **publique** du CDN pour signer
ses liens de téléchargement. Derrière un routeur NAT, ce paquet ne revient pas
tout seul, et l'export échoue sur un message qui parle de stockage alors que le
problème est un routage. Le `docker-compose.yml` fait pointer ce nom vers l'hôte
pour ce seul conteneur : le cas est traité, en production comme en local.

---

## L'email : facultatif

**Aucun serveur SMTP n'est nécessaire.** L'inscription n'envoie pas de mail, il n'y
a pas de vérification d'adresse, et la connexion n'en a pas besoin. Le client mail
du backend rend `nil` dès qu'une des trois variables est vide, et il n'est appelé
qu'à un seul endroit : la demande de réinitialisation de mot de passe.

Sans SMTP, la seule chose qui manque est donc le lien « mot de passe oublié ».

Pour l'activer, remplir dans le `.env` :

```env
SMTP_HOST=smtp.exemple.fr
SMTP_MAIL=alexandrie@exemple.fr      # sert d'identifiant ET d'expéditeur
SMTP_PASSWORD=...
SMTP_MAIL_FROM=                      # facultatif : change l'expéditeur affiché
```

puis `make install`. Deux pièges :

- le backend force le **SSL implicite**, c'est-à-dire le **port 465**. Un serveur
  qui n'écoute qu'en STARTTLS sur 587 ne fonctionnera pas ;
- `SMTP_MAIL` est à la fois l'identifiant d'authentification et l'adresse
  d'expédition. Ce n'est pas deux réglages, c'est un seul.

---

## Combien de mémoire ça mange

Mesuré le 17 août 2026 sur cette stack, sous une charge de 150 pages et 150 appels
API simultanés — repos → pic :

| Service | Défauts de l'amont | Avec les réglages livrés ici |
|---|---|---|
| MySQL | 423 → 437 Mo | **129 → 141 Mo** |
| Frontend (Nuxt) | 86 → **345 Mo** | **25 → 80 Mo** |
| RustFS | 176 → 177 Mo | 70 → 79 Mo |
| Backend (Go) | 9 → 15 Mo | 8 → 11 Mo |
| **Total** | **694 → 974 Mo** | **232 → 311 Mo** |

Deux réglages font tout le gain, et aucun ne dégrade le service.

**`PERFORMANCE_SCHEMA=OFF` divise MySQL par deux.** Mesure interne : cette
instrumentation occupait **230 Mo**, davantage qu'InnoDB lui-même. C'est un outil
de diagnostic ; le remettre à `ON` le temps d'enquêter sur une lenteur, puis le
recouper.

**`TAS_NODE_MO` dit à V8 où est le plafond.** Sans lui, Node dimensionne son tas
d'après la mémoire visible de la **machine** — 30 Gio sur le poste de mesure — et
laisse donc enfler jusqu'à 345 Mo avant de ramasser. Avec, il ramasse tôt et
plafonne à 80 Mo, pour le même travail et sans ralentissement mesurable. Ce n'était
pas une fuite : le tas redescendait tout seul en 90 secondes. Mais sur un petit
serveur, une pointe de trafic suffit à épuiser la RAM de l'hôte — et c'est alors le
noyau qui choisit quoi tuer, possiblement MySQL en pleine écriture.

Les `LIMITE_MEMOIRE_*` sont des plafonds de conteneur : elles ne réservent rien,
elles font qu'un dérapage tue **le conteneur fautif**, qui redémarre, plutôt que la
machine.

**Un serveur à 2 Gio suffit largement** : ~310 Mo de pic pour Alexandrie, ~280 Mo
pour Traefik et CrowdSec, le reste pour le système et le cache disque. Prévoir en
revanche l'espace disque du stockage S3, qui, lui, grandit avec les fichiers.

---

## Deux propriétés d'Alexandrie qu'il vaut mieux connaître

**Les fichiers téléversés sont lisibles par tout le monde.** Le backend pose sur le
bucket une politique `s3:GetObject` pour `Principal: {"AWS":["*"]}` — vérifié dans
`app/minio.go`, et vérifié en pratique : un objet se récupère en 200 sans cookie ni
signature. Rendre un document privé ne protège **pas** ses pièces jointes ; seule
l'imprévisibilité de leur identifiant les cache. À savoir avant d'y déposer un
scan de pièce d'identité.

**La sauvegarde du stockage S3 est prise à chaud.** Le dump MySQL est cohérent
(`--single-transaction`), mais le stockage objet n'a pas d'équivalent : un fichier
d'index en cours d'écriture peut partir déchiré dans l'archive. En pratique
l'écriture d'un objet dure quelques millisecondes et le risque est faible, mais il
n'est pas nul. Pour une sauvegarde parfaitement cohérente, `make stop` avant
`make backup` — au prix de la coupure.

---

## Ce que ce dépôt ne fait pas

- Il **n'installe pas Docker**, ni Traefik, ni borgwarehouse.
- Il **ne compile pas** Alexandrie : il tire les images publiées par l'amont.
- Il **ne pose pas de cron** sans qu'on le lui demande : `make backup` propose la
  fréquence à la configuration, et « aucune » est une réponse valable.
- Il **ne teste pas votre copie de coffre-fort.** `make verif-archive` utilise le
  `.env` de la machine, pas la passphrase archivée ailleurs — or c'est celle-là,
  et elle seule, qui servira le jour où la machine aura brûlé. À vérifier une
  fois, à la main, depuis une **autre** machine.

---

## Licence et amont

L'application : [Smaug6739/Alexandrie](https://github.com/Smaug6739/Alexandrie),
sa documentation dans [`docs/`](https://github.com/Smaug6739/Alexandrie/tree/main/docs)
et son [Discord](https://discord.gg/UPsEg6egPj).
Ce dépôt d'hébergement : voir [LICENSE](./LICENSE).
