#!/bin/bash
# =============================================================================
# bin/init_backup.sh — Configure la sauvegarde borg d'Alexandrie
# / bin/init_backup.sh — Sets up Alexandrie's borg backup
#
# S'EXECUTE DEPUIS L'HOTE, et il est INTERACTIF.  Lance par :
#     make backup
#
# Enchaine : cle SSH dediee -> creation du depot sur borgwarehouse ->
# ecriture du .env -> borg init -> mise au coffre -> cron -> premiere
# sauvegarde -> verification.
#
# REJOUABLE. Le seul cas ou ce script refuse d'aller plus loin, c'est
# quand le depot configure contient DEJA DES ARCHIVES : regenerer une
# passphrase les rendrait definitivement illisibles. Dans tous les autres
# cas — API injoignable, `borg init` rate, Ctrl-C en plein milieu — on le
# relance : il reprend ce qui existe au lieu de l'ecraser.
# / Replayable. It only refuses when the repository already holds
# archives: a new passphrase would make them unreadable forever.
#
# LE JETON BORGWAREHOUSE
#
# Ce script ne fait QU'UN appel a l'API : le POST qui cree le depot. Un
# jeton avec la seule permission « create » suffit (Account >
# Integrations). Tout le reste — init, create, prune, list — passe par SSH
# avec la cle dediee. S'il fuite, un jeton create-only ne permet ni de
# lister ni de supprimer les depots.
#
# Il est lu, dans l'ordre, dans `borgwarehouse_ccc_api` puis
# `BW_API_TOKEN`, et a defaut saisi au clavier. Il n'est stocke nulle part.
# / Read from borgwarehouse_ccc_api, then BW_API_TOKEN, else typed in.
# Never stored.
# =============================================================================
set -euo pipefail

REPERTOIRE_DU_SCRIPT="$(cd -- "$(dirname -- "$0")" && pwd)"
REPERTOIRE_DU_PROJET="$(dirname "$REPERTOIRE_DU_SCRIPT")"
FICHIER_ENV="${ENV_FILE:-$REPERTOIRE_DU_PROJET/.env}"

SCRIPT_DE_SAUVEGARDE="$REPERTOIRE_DU_SCRIPT/backup.sh"
SCRIPT_DE_VERIFICATION="$REPERTOIRE_DU_SCRIPT/verifier_archive.sh"

# L'ADRESSE DU SERVEUR DE SAUVEGARDE VIENT DU .env, PAS D'ICI.
#
# Elle a d'abord ete ecrite en dur dans ce fichier. C'est une mauvaise
# place pour elle : ce script est versionne et pousse sur une forge, et
# l'adresse designe VOTRE serveur de sauvegarde. La publier revient a
# indiquer ou sont les archives de toutes les machines qui l'utilisent.
#
# `make install` pose la question et ecrit la reponse dans le .env, que
# git ignore. Ici, on ne fait que la relire : le defaut visible ci-dessous
# n'est qu'un exemple, et la question reste posee si la valeur manque.
# / It lived hard-coded here: a bad place, since this file is pushed to a
# forge and the address names YOUR backup server.
URL_BWH_PAR_DEFAUT="https://borgwarehouse.exemple.fr"
PORT_SSH_BWH_PAR_DEFAUT="2226"

dire()   { echo "[init] $*"; }
erreur() { echo "[init] ERREUR : $*" >&2; exit 1; }
demander() {  # demander <invite> [defaut] -> reponse sur stdout
    local invite="$1" defaut="${2:-}" reponse=""
    if [ -n "$defaut" ]; then
        read -r -p "$invite [$defaut] : " reponse || true
        echo "${reponse:-$defaut}"
    else
        read -r -p "$invite : " reponse || true
        echo "$reponse"
    fi
}


#### PREREQUIS ####
[ -t 0 ] || erreur "make backup est interactif : le lancer depuis un terminal."
[ -f "$FICHIER_ENV" ] || erreur ".env introuvable. Commencer par :  make install"

for outil in borg ssh-keygen openssl curl crontab docker; do
    command -v "$outil" >/dev/null || erreur "$outil introuvable dans le PATH."
done

valeur_du_env() {
    sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$FICHIER_ENV" | tail -n1 | tr -d "'\""
}
BORG_PREFIX="$(valeur_du_env BORG_PREFIX)"
BORG_REPO="$(valeur_du_env BORG_REPO)"
BORG_PASSPHRASE="$(valeur_du_env BORG_PASSPHRASE)"

# Repris du .env, ou `make install` les a ecrits. Vides — installation
# faite avant que la question n'existe, ou reponse passee — on retombe sur
# l'exemple, et la question sera posee plus bas comme avant.
# / Read from the .env where `make install` wrote them; empty falls back
# to the example and the question is asked as before.
URL_BWH_DU_ENV="$(valeur_du_env BORGWAREHOUSE_URL)"
PORT_BWH_DU_ENV="$(valeur_du_env BORGWAREHOUSE_SSH_PORT)"
[ -n "$URL_BWH_DU_ENV" ]  && URL_BWH_PAR_DEFAUT="$URL_BWH_DU_ENV"
[ -n "$PORT_BWH_DU_ENV" ] && PORT_SSH_BWH_PAR_DEFAUT="$PORT_BWH_DU_ENV"


#### GARDE-FOU : NE JAMAIS RENDRE DES ARCHIVES ILLISIBLES ####
# La vraie question n'est pas « le .env est-il rempli ? » mais « y a-t-il
# des archives a proteger ? ». Un .env rempli et un depot vide, c'est un
# init precedent arrete en route : on doit pouvoir reprendre.
# / The question is not "is the .env filled?" but "are there archives?".
REPRISE=0
if [ -n "$BORG_REPO" ] && [ -n "$BORG_PASSPHRASE" ]; then
    dire "une configuration existe deja dans le .env — j'interroge le depot..."
    CLE_EXISTANTE="$REPERTOIRE_DU_SCRIPT/.ssh/${BORG_PREFIX}_ed25519"
    [ -f "$CLE_EXISTANTE" ] && export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i '$CLE_EXISTANTE'"

    if ARCHIVES="$(BORG_PASSPHRASE="$BORG_PASSPHRASE" borg list --short "$BORG_REPO" 2>/dev/null)" && [ -n "$ARCHIVES" ]; then
        NOMBRE="$(wc -l <<< "$ARCHIVES")"
        echo >&2
        echo "[init] Le depot contient deja $NOMBRE archive(s)." >&2
        echo >&2
        echo "  Ce script s'arrete ici, VOLONTAIREMENT." >&2
        echo "  Regenerer une passphrase rendrait ces archives" >&2
        echo "  DEFINITIVEMENT ILLISIBLES." >&2
        echo >&2
        echo "  Verifier la sauvegarde en place :   make verif-archive" >&2
        exit 1
    fi

    dire "depot vide ou injoignable : je reprends la ou la configuration s'est arretee."
    REPRISE=1
fi


#### 1. PREFIXE ET FREQUENCE ####
echo
dire "Configuration de la sauvegarde d'Alexandrie (base + stockage S3 + .env)."
echo

if [ "$REPRISE" = 0 ]; then
    # Le prefixe vient du NOM DE LA MACHINE, il n'est pas demande. Il sert
    # a deux choses, et le nom de machine convient aux deux : il nomme les
    # archives — c'est ce qui permet de reconnaitre d'ou vient une
    # sauvegarde quand plusieurs machines partagent un serveur — et il
    # nomme la cle SSH du depot, qui doit etre unique sur la machine.
    # C'est aussi une question de moins a poser.
    #
    # Tout caractere hors [a-zA-Z0-9_-] casserait le nom des archives et le
    # glob de la rotation : on les remplace par des tirets plutot que de
    # refuser un nom de machine que l'utilisateur ne choisit pas.
    # / The prefix comes from the machine's name; characters outside
    # [a-zA-Z0-9_-] would break the prune glob.
    NOM_DE_LA_MACHINE="$(hostname -s 2>/dev/null || echo '')"
    NOM_DE_LA_MACHINE="${NOM_DE_LA_MACHINE//[^a-zA-Z0-9_-]/-}"
    [ -n "$NOM_DE_LA_MACHINE" ] || NOM_DE_LA_MACHINE="sans-nom"
    BORG_PREFIX="alexandrie-$NOM_DE_LA_MACHINE"
    dire "prefixe des archives : $BORG_PREFIX (le nom de cette machine)"
else
    dire "prefixe repris du .env : $BORG_PREFIX"
fi

# La frequence est demandee AVANT la creation du depot : elle determine
# l'alerte borgwarehouse ET le seuil de `make verif-archive`, qui doivent
# rester coherents entre eux.
# / Frequency drives both the BWH alert and the check threshold.
echo
dire "Frequence de sauvegarde :"
echo "   1) quotidienne (recommande)"
echo "   2) horaire"
echo "   3) hebdomadaire"
echo "   4) aucune (je poserai le cron moi-meme)"
case "$(demander "Ton choix" "1")" in
    2) PLANIFICATION="@hourly" ; ALERTE=21600  ; AGE_MAX=2   ;;
    3) PLANIFICATION="@weekly" ; ALERTE=864000 ; AGE_MAX=169 ;;
    4) PLANIFICATION=""        ; ALERTE=90000  ; AGE_MAX=25  ;;
    *) PLANIFICATION="@daily"  ; ALERTE=90000  ; AGE_MAX=25  ;;
esac


#### 2. CLE SSH DEDIEE (une cle = un depot) ####
CLE_SSH="$REPERTOIRE_DU_SCRIPT/.ssh/${BORG_PREFIX}_ed25519"
if [ -f "$CLE_SSH" ]; then
    dire "cle SSH existante reutilisee : $CLE_SSH"
else
    mkdir -p "$REPERTOIRE_DU_SCRIPT/.ssh"
    chmod 700 "$REPERTOIRE_DU_SCRIPT/.ssh"
    ssh-keygen -t ed25519 -N '' -C "borg-$BORG_PREFIX" -f "$CLE_SSH" >/dev/null
    dire "cle SSH generee : $CLE_SSH"
fi
chmod 600 "$CLE_SSH"
export BORG_RSH="/usr/bin/ssh -oStrictHostKeyChecking=accept-new -oIdentitiesOnly=yes -i '$CLE_SSH'"


#### 3. PASSPHRASE ####
# En hexadecimal, PAS en base64 : ce .env est aussi lu par docker compose,
# dont l'analyseur interprete `$`. Une passphrase base64 contenant un `$`
# produirait une valeur differente cote conteneur et cote script — le
# depot deviendrait illisible depuis l'un des deux, sans un mot. 32 octets
# hexadecimaux, c'est toujours 256 bits d'entropie.
# / Hex, not base64: compose interprets `$`. Same 256 bits of entropy.
[ -n "$BORG_PASSPHRASE" ] || BORG_PASSPHRASE="$(openssl rand -hex 32)"
export BORG_PASSPHRASE


#### 4. LE DEPOT SUR BORGWAREHOUSE ####
if [ -z "$BORG_REPO" ]; then
    echo
    dire "Creation du depot sur borgwarehouse."
    dire "(Sur un poste de dev, on peut aussi donner un CHEMIN ABSOLU local"
    dire " a la derniere question : borg cree alors un depot sur le disque.)"
    echo

    URL_BWH="$(demander "URL de borgwarehouse" "$URL_BWH_PAR_DEFAUT")"
    PORT_SSH_BWH="$(demander "Port SSH de borgwarehouse" "$PORT_SSH_BWH_PAR_DEFAUT")"

    # Le jeton vient de l'environnement quand il y est — c'est le cas sur
    # les serveurs de production — et du clavier sinon.
    JETON="${borgwarehouse_ccc_api:-${BW_API_TOKEN:-}}"
    if [ -n "$JETON" ]; then
        dire "jeton trouve dans l'environnement : creation automatique du depot."
    else
        dire "Un jeton API automatise cette etape (Account > Integrations)."
        dire "La permission 'create' SEULE suffit : c'est le seul appel qu'on fait."
        read -r -s -p "[init] Jeton API borgwarehouse (vide = methode manuelle) : " JETON || true
        echo
    fi

    if [ -n "$JETON" ]; then
        QUOTA="$(demander "Quota du depot, en Go" "20")"
        dire "POST $URL_BWH/api/v1/repositories"
        REPONSE="$(curl -sS --fail-with-body -X POST "$URL_BWH/api/v1/repositories" \
            -H "Authorization: Bearer $JETON" \
            -H "Content-Type: application/json" \
            --data-binary @- <<EOF || erreur "l'appel a l'API a echoue (jeton invalide ? URL incorrecte ?). Relancer make backup : rien n'est perdu."
{
  "alias": "$BORG_PREFIX",
  "sshPublicKey": "$(cat "${CLE_SSH}.pub")",
  "storageSize": $QUOTA,
  "comment": "Alexandrie — cree par make backup",
  "alert": $ALERTE,
  "lanCommand": false,
  "appendOnlyMode": false
}
EOF
)"
        # Reponse : {"id":2,"repositoryName":"c1ddd097"}. L'adresse SSH n'y
        # figure pas : elle est deterministe, on la reconstruit.
        # / The SSH address is deterministic; we rebuild it.
        NOM_DU_DEPOT="$(printf '%s' "$REPONSE" | sed -n 's/.*"repositoryName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
        [ -n "$NOM_DU_DEPOT" ] || erreur "reponse inattendue de l'API : $REPONSE"
        HOTE_BWH="$(printf '%s' "$URL_BWH" | sed -e 's#^https\?://##' -e 's#/.*##')"
        BORG_REPO="ssh://borgwarehouse@$HOTE_BWH:$PORT_SSH_BWH/./$NOM_DU_DEPOT"
        dire "depot cree : $NOM_DU_DEPOT"
    else
        echo
        dire "Sur $URL_BWH :"
        dire "  1. New repository"
        dire "  2. coller la cle publique ci-dessous"
        dire "  3. regler Alert (c'est elle qui previendra si une sauvegarde manque)"
        dire "  4. copier l'adresse SSH du depot"
        echo
        cat "${CLE_SSH}.pub"
        echo
    fi

    BORG_REPO="$(demander "Adresse du depot (ssh://... ou chemin absolu)" "$BORG_REPO")"
    case "$BORG_REPO" in
        ssh://*|/*) : ;;
        *) erreur "adresse invalide : elle doit commencer par ssh:// (ou / pour un depot local)." ;;
    esac
else
    dire "depot repris du .env : $BORG_REPO"
fi
export BORG_REPO


#### 5. ECRITURE DU .env, PUIS INIT DU DEPOT ####
# Le .env est ecrit AVANT `borg init` : si l'init echoue, la passphrase
# n'est pas perdue et le script peut etre relance (le garde-fou verra un
# depot sans archive).
# / Written first: a failed init must not lose the passphrase.
if [ "$REPRISE" = 0 ]; then
    {
        echo ""
        echo "# --- Sauvegarde borg — ecrit par make backup le $(date +%Y-%m-%d) ---"
        echo "BORG_PREFIX=$BORG_PREFIX"
        echo "BORG_REPO=$BORG_REPO"
        echo "BORG_PASSPHRASE='$BORG_PASSPHRASE'"
        echo "AGE_MAX_HEURES=$AGE_MAX"
    } >> "$FICHIER_ENV"
    chmod 600 "$FICHIER_ENV"
    dire "$FICHIER_ENV complete."
else
    # A LA REPRISE, LE SEUIL SUIT LA FREQUENCE. La question de la frequence
    # est reposee a chaque passage ; ne pas reecrire AGE_MAX_HEURES
    # laisserait un cron horaire sous un seuil de 25 h — la verification
    # resterait alors au vert vingt-cinq heures apres l'arret d'une
    # sauvegarde qui devait tourner chaque heure.
    # / On resume, the threshold must follow the frequency.
    if grep -q '^AGE_MAX_HEURES=' "$FICHIER_ENV"; then
        sed -i "s|^AGE_MAX_HEURES=.*|AGE_MAX_HEURES=$AGE_MAX|" "$FICHIER_ENV"
    else
        echo "AGE_MAX_HEURES=$AGE_MAX" >> "$FICHIER_ENV"
    fi
    dire "seuil de fraicheur mis a jour : $AGE_MAX h."
fi

if borg list "$BORG_REPO" >/dev/null 2>&1; then
    dire "depot deja initialise."
else
    dire "initialisation du depot (repokey-blake2)..."
    borg init -e repokey-blake2 "$BORG_REPO"
fi


#### 6. LE COFFRE-FORT ####
# TOUT EST AFFICHE, EN ENTIER, D'UN SEUL BLOC. Ce que l'on ne voit pas, on
# ne le copie pas : afficher le CHEMIN de la cle privee obligerait a aller
# chercher le fichier — ce qu'on ne fait pas a 2 h du matin — et la cle
# resterait sur la machine, la seule qui ne sera plus la le jour ou on en
# aura besoin.
#
# QUATRE elements, pas trois. L'adresse, la passphrase et `borg key export`
# ouvrent le CHIFFREMENT ; la cle SSH privee ouvre l'ACCES. Sur
# borgwarehouse, le depot n'accepte que la cle publique enregistree sur
# lui : sans la privee, une machine de secours se fait refuser par SSH
# avant meme d'avoir a prouver qu'elle connait la passphrase.
#
# Le NOM du fichier compte : les scripts cherchent
# `bin/.ssh/${BORG_PREFIX}_ed25519`, et une cle reposee sous un autre nom
# n'est simplement pas vue — ssh se rabat alors sur la config systeme, et
# le refus parle de permissions, jamais de nom de fichier. C'est pourquoi
# le bloc porte la recette de restauration complete.
# / Everything in full, in one block. Four items, not three. The file NAME
# matters.
echo
echo "================================================================"
echo " A METTRE AU COFFRE-FORT NUMERIQUE, MAINTENANT."
echo
echo " Tout ce qui suit, jusqu'a la ligne de fin : selectionne, copie,"
echo " colle dans le coffre. Sans ces elements, les archives sont un"
echo " bloc chiffre definitivement illisible — c'est le seul maillon"
echo " que la sauvegarde ne peut pas se sauvegarder elle-meme."
echo "================================================================"
echo
echo "----8<---- COPIER A PARTIR D'ICI --------------------------------"
echo "Alexandrie — sauvegarde borg"
echo "Machine : $(hostname -f 2>/dev/null || hostname)"
echo "Date    : $(date +%Y-%m-%d)"
echo
echo "# Les lignes du .env, a remettre telles quelles :"
echo "BORG_PREFIX=$BORG_PREFIX"
echo "BORG_REPO=$BORG_REPO"
echo "BORG_PASSPHRASE='$BORG_PASSPHRASE'"
# AGE_MAX_HEURES fait partie du bloc. Sans elle, une machine qui
# sauvegardait toutes les heures repart apres sinistre avec le seuil par
# defaut de 25 h : la verification reste au vert vingt-cinq heures apres
# l'arret d'une sauvegarde horaire. Le meme piege que la reprise
# d'installation corrige plus haut, un sinistre plus loin.
# / Without it, an hourly machine comes back with the 25 h default.
echo "AGE_MAX_HEURES=$AGE_MAX"
echo
echo "# Cle SSH PRIVEE du depot — elle ouvre l'ACCES."
echo "# A reposer dans :  bin/.ssh/${BORG_PREFIX}_ed25519   (chmod 600)"
cat "$CLE_SSH"
echo
echo "# Cle de chiffrement du depot (borg key export) :"
borg key export "$BORG_REPO"
echo
echo "# RESTAURER SUR UNE AUTRE MACHINE"
echo "#   git clone <le depot git> && cd Alexandrie"
echo "#   make install                    # repond aux 2 questions"
echo "#   # ajouter les lignes BORG_* et AGE_MAX_HEURES ci-dessus au .env"
echo "#   mkdir -p bin/.ssh && chmod 700 bin/.ssh"
echo "#   # coller la cle privee dans bin/.ssh/${BORG_PREFIX}_ed25519"
echo "#   chmod 600 bin/.ssh/${BORG_PREFIX}_ed25519"
echo "#   make restore"
echo "----8<---- JUSQU'ICI --------------------------------------------"
echo
echo " Si la cle privee est perdue, il restera a coller une nouvelle cle"
echo " publique sur le depot depuis l'interface de borgwarehouse."
echo
echo " Ces secrets sont maintenant dans l'historique de ce terminal."
echo " Le fermer une fois la copie faite."
echo
[ "$(demander "Taper OUI quand TOUT est copie au coffre" "")" = "OUI" ] \
    || erreur "abandon. Le depot et le .env sont en place : relancer make backup quand tu es pret (il reprendra ici)."


#### 7. CRON ####
if [ -n "$PLANIFICATION" ]; then
    # Le journal ne va pas dans /var/log : un non-root ne peut pas y
    # ecrire, et si la redirection echoue, cron n'execute meme pas la
    # commande — zero sauvegarde, zero trace.
    # / Not in /var/log: if the redirection fails, cron does not even run
    # the command.
    JOURNAL="$HOME/.borg-backup-$BORG_PREFIX.log"
    # LE `PATH` EST FIGE DANS LA LIGNE, et ce n'est pas un ornement. Cron
    # tourne avec un PATH minimal (souvent `/usr/bin:/bin`). Un `borg`
    # installe par pipx dans `~/.local/bin` — le cas courant, borg 1.4
    # n'etant pas dans les depots de toutes les distributions — n'y est
    # PAS : bin/backup.sh sort alors sur « borg introuvable dans le
    # PATH », la ligne part dans un journal que personne ne lit, et plus
    # aucune sauvegarde n'est prise. La panne est silencieuse et totale.
    # / cron runs with a minimal PATH: a borg installed in ~/.local/bin
    # is not found, and the backups stop, silently.
    LIGNE_DE_CRON="$PLANIFICATION PATH=$PATH bash $SCRIPT_DE_SAUVEGARDE >> $JOURNAL 2>&1"
    # `crontab -l` sort en erreur quand le crontab est vide : on absorbe.
    CRON_ACTUEL="$(crontab -l 2>/dev/null || true)"
    # On matche le chemin ABSOLU : plusieurs sauvegardes peuvent cohabiter
    # sur une machine, un grep laxiste en priverait une.
    # DEUX LIGNES, PAS UNE. La premiere sauvegarde ; la seconde VERIFIE.
    #
    # Poser la sauvegarde seule laissait le dispositif borgne : rien, sur
    # la machine, ne se serait apercu qu'un dump partait tronque nuit
    # apres nuit. L'alerte de borgwarehouse ne regarde que la DATE de la
    # derniere archive — une archive fraiche et inexploitable la laisse
    # au vert. bin/verifier_archive.sh, lui, sort en code non nul des que
    # quelque chose cloche, et cron envoie sa sortie par courriel.
    #
    # Il tourne une heure APRES la sauvegarde (`@daily` = minuit, donc
    # 1 h du matin) : verifier avant qu'elle soit prise n'aurait aucun
    # sens. / Two lines: one backs up, the other CHECKS. Borgwarehouse's
    # alert only looks at the DATE of the last archive, so a fresh but
    # unusable archive leaves it green.
    JOURNAL_VERIF="$HOME/.borg-verif-$BORG_PREFIX.log"
    case "$PLANIFICATION" in
        @hourly) PLANIF_VERIF="30 * * * *" ;;
        @weekly) PLANIF_VERIF="0 1 * * 1"  ;;
        *)       PLANIF_VERIF="0 1 * * *"  ;;
    esac
    LIGNE_DE_VERIF="$PLANIF_VERIF PATH=$PATH bash $SCRIPT_DE_VERIFICATION >> $JOURNAL_VERIF 2>&1"

    # LES DEUX LIGNES SONT TESTEES SEPAREMENT. Un test sur la seule ligne
    # de sauvegarde laissait pour toujours sans verification les machines
    # configurees AVANT que la seconde ligne n'existe : « une ligne de
    # cron existe deja — inchangee », et le dispositif restait borgne.
    # / Tested independently: testing only the backup line left every
    # machine configured before the second line existed permanently blind.
    A_AJOUTER=""
    grep -Fq "$SCRIPT_DE_SAUVEGARDE" <<< "$CRON_ACTUEL" \
        || A_AJOUTER="$LIGNE_DE_CRON"
    grep -Fq "$SCRIPT_DE_VERIFICATION" <<< "$CRON_ACTUEL" \
        || A_AJOUTER="$A_AJOUTER${A_AJOUTER:+$'\n'}$LIGNE_DE_VERIF"

    if [ -z "$A_AJOUTER" ]; then
        dire "les deux lignes de cron existent deja — inchangees."
        dire "  Verifier qu'elles suivent la frequence choisie :  crontab -l"
    else
        printf '%s\n%s\n' "$CRON_ACTUEL" "$A_AJOUTER" \
            | grep -v '^[[:space:]]*$' | crontab -
        dire "cron pose :"
        printf '%s\n' "$A_AJOUTER" | sed 's/^/[init]   /'
    fi
fi


#### 8. PREMIERE SAUVEGARDE, ET VERIFICATION ####
echo
dire "premiere sauvegarde..."
bash "$SCRIPT_DE_SAUVEGARDE"
echo
dire "verification..."
bash "$SCRIPT_DE_VERIFICATION"
echo
dire "termine."
dire "  Le controle rapide, non destructif :  make verif-archive"
dire "  La repetition generale (elle eteint le site) :  make backup-check"
