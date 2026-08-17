#!/bin/bash
# =============================================================================
# bin/verifier_http.sh — Une URL repond-elle ce qu'elle doit repondre ?
# / bin/verifier_http.sh — Does a URL answer what it is supposed to?
#
# S'EXECUTE DEPUIS L'HOTE. Appele par bin/check_backup.sh et bin/update.sh.
#
# USAGE
#   bash bin/verifier_http.sh <libelle> <url> <motif de codes acceptes>
#   -> affiche une ligne [ok] ou [KO], et sort en 0 ou 1
#
#   ex. bash bin/verifier_http.sh "site" https://x.fr/ '^[23]'
#
# POURQUOI UN MOTIF PLUTOT QUE « TOUT SAUF 5xx »
#
# Ce script a d'abord accepte n'importe quel code hors 5xx. La repetition
# generale du 16 aout 2026 est alors passee AU VERT sur un site qui
# rendait 404 : Traefik repond 404 quand AUCUN routeur ne correspond a
# l'hote demande — c'est-a-dire quand le site n'est pas branche du tout.
# Le pire code possible pour une page d'accueil etait compte comme un
# succes. / Traefik answers 404 when NO router matches the host: the worst
# possible code for a home page was being counted as a success.
#
# Chaque appelant declare donc ce qu'il attend :
#   la page d'accueil    '^[23]'   200, ou une redirection
#   l'API                '^[24]'   404 = la route existe, l'objet non
#   la racine du CDN     '^[24]'   403 = le listage est interdit, c'est bien
#   un fichier restaure  '^2'      200 et rien d'autre
#
# POURQUOI IL REESSAIE
#
# Traefik decouvre les conteneurs par les evenements Docker : entre le
# demarrage d'un conteneur et l'existence de sa route, il s'ecoule un
# court instant. Un controle tire aussitot apres un `up -d` tombe dans ce
# trou et rend 404. Reessayer quelques secondes distingue « pas encore
# branche » de « pas branche ». Le succes sort AU PREMIER essai reussi :
# quand tout va bien, ce script ne coute rien.
# / Traefik discovers containers through Docker events; a check fired
# right after `up -d` falls into that gap. Retrying tells "not yet" from
# "not at all", and success exits on the first try.
# =============================================================================
set -uo pipefail

LIBELLE="${1:?usage: verifier_http.sh <libelle> <url> <motif>}"
URL="${2:?usage: verifier_http.sh <libelle> <url> <motif>}"
MOTIF="${3:?usage: verifier_http.sh <libelle> <url> <motif>}"

DUREE_MAX="${DUREE_MAX_HTTP:-45}"

DEBUT=$(date +%s)
while :; do
    # -k : sur un poste de dev le certificat est auto-signe. Ce controle
    # repond a « le service est-il joignable a travers le proxy ? », pas a
    # « le certificat est-il valide ? ». En production, la validite du
    # certificat se voit dans un navigateur, pas ici.
    # / -k: this asks whether the service answers through the proxy.
    CODE="$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || echo 000)"

    if [[ "$CODE" =~ $MOTIF ]]; then
        echo "  [ok]   $LIBELLE : $CODE"
        exit 0
    fi

    [ $(( $(date +%s) - DEBUT )) -ge "$DUREE_MAX" ] && break
    sleep 3
done

case "$CODE" in
    000) echo "  [KO]   $LIBELLE : aucune reponse apres ${DUREE_MAX} s ($URL)" >&2 ;;
    404) echo "  [KO]   $LIBELLE : 404 apres ${DUREE_MAX} s ($URL)" >&2
         echo "         Un 404 sur cet hote vient en general de TRAEFIK, pas de" >&2
         echo "         l'application : aucun routeur ne correspond a ce nom." >&2
         echo "         Verifier que le conteneur est sur le reseau du proxy et" >&2
         echo "         que DOMAIN dans le .env correspond a l'URL demandee." >&2 ;;
    5*)  echo "  [KO]   $LIBELLE : erreur serveur $CODE ($URL)" >&2
         echo "         Le proxy a trouve le service mais celui-ci ne repond pas." >&2
         echo "         Les journaux :  make logs" >&2 ;;
    *)   echo "  [KO]   $LIBELLE : code inattendu $CODE ($URL)" >&2 ;;
esac
exit 1
