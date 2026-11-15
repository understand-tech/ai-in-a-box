# Frontières des API

[English](api-boundaries.md) | [Français](api-boundaries.fr.md)

Pour les opérateurs et contributeurs qui vérifient quels appelants peuvent atteindre
une surface HTTP. La même classification vaut pour une installation autonome, une
plateforme avec machine de calcul séparée et une paire à haute disponibilité.

## Surfaces

| Surface | Appelants prévus | Entrée et contrôle |
|---|---|---|
| API produit | Navigateurs et intégrations autorisées | Entrée HTTPS plateforme ou administration ; authentification et droits sur les ressources dans l’application |
| API applicative | Utilisateurs d’une application | Hôte et backend de l’application ; contrat et autorisation propres |
| Appels entre services sur une machine | Conteneurs de service autorisés | Réseaux privés et credentials de service ; aucun port hôte publié par défaut |
| Liens entre machines du produit | Machines appairées | Listener dédié avec certificats clients vérifiés ; voir [certificats et DNS](certificates-and-dns.md) |
| Exploitation et supervision | Sondes locales et collecteur | Contrôles locaux au conteneur ou réseau dédié aux métriques ; aucune entrée produit |

Un administrateur qui utilise le produit passe toujours par l’API produit. Un endpoint
métriques d’exploitation constitue une autre surface. L’authentification du proxy ne
remplace pas les contrôles du service destinataire sur l’action et la ressource.

## Routage produit

`Caddyfile` porte les entrées plateforme et administration. Leur règle commune
`product_api_boundary` réserve les espaces `internal` et `operator` à la racine,
sous `/api` et sous `/api/v3`, ainsi que les chemins de documentation et de métriques
des API, hors de ces entrées. Les sondes de santé à
l’intérieur des conteneurs API conservent leurs adresses. Les routes produit gardent
leurs destinations ; cette modification ne remplace pas l’API existante.

Les chemins API contenant des encodages structurels, segments pointés ou séparateurs
répétés sont refusés. Les noms normalement encodés, comme les espaces, et les paramètres
de requête restent acceptés. Le contrôle précède le choix de l’upstream et ne dépend
pas des credentials. Une route hors de cette surface reçoit 404.

Les API produit existantes restent routées par leurs espaces historiques. Ce n’est
pas un nouveau contrat exhaustif de leurs opérations. Chaque nouvelle surface doit
lister explicitement ses méthodes et chemins publiés ; son extension exige les tests
de contrat, d’autorisation et d’entrée correspondants.

Les hôtes applicatifs et applications générées gardent leurs propres contrats. Une
règle générique de plateforme ne doit pas réserver un chemin dans l’application d’un
autre propriétaire. Celui-ci classe ses routes et contrôle leur accès. Les liens
entre machines conservent leurs règles d’admission et leur TLS mutuel.

Les compteurs de Caddy restent sur le listener et le réseau du collecteur. Publier
un port de service pour contourner le routage n’est pas un moyen pris en charge
pour rendre une opération disponible.

## Qualifier une modification de routage

1. Dans une même PR, mettre à jour le routage, cette référence et `test/ingress.sh`.
   La CI exécute le Caddy épinglé avec de faux upstreams et vérifie les destinations
   produit existantes, les méthodes et chemins refusés, les variantes encodées et
   l’absence d’appel amont lors d’un refus. La même frontière API est exercée avec
   les TLS `internal`, `custom` et `edge`. Les tests de l’application vérifient son
   authentification.
2. Garder `test/migration.sh` fondé sur `origin/main` : la version en service est
   l’état de départ. Ce changement de routage n’ajoute lui-même aucun réglage, port
   ou migration de données ; la version complète peut contenir d’autres changements
   couverts par la recette de mise à jour.
3. Avant activation, relever paquet et configuration actifs, puis les parcours de
   référence réussis : connexion, opération API authentifiée, appel d’intégration
   lorsque configuré et collecte de supervision. Suivre la [mise à jour gérée](update.md)
   habituelle ; ne pas modifier à la main un Caddyfile déployé.
4. Avant de rendre l’installation aux utilisateurs, rejouer ces parcours et vérifier
   que les routes de service/exploitation restent hors de l’entrée produit. Un parcours
   auparavant valide qui échoue, une route interdite qui atteint un upstream ou la perte
   d’une cible de supervision auparavant saine arrête la recette. L’opérateur consigne
   parcours, statut HTTP et version du paquet sans credential ni contenu utilisateur.
5. Corriger la route publiée exacte ou suivre la [procédure de récupération](update.md#if-the-update-goes-wrong).
   Restaurer le paquet précédent restaure aussi son routage : c’est une récupération,
   pas une preuve que la nouvelle frontière fonctionne. Le changement reste ouvert
   jusqu’à vérification de la politique voulue et des parcours produit.

Un test proxy réussi ne constitue ni une preuve de déploiement ni une preuve des droits
sur les ressources applicatives. Consigner séparément les résultats d’activation avec
la version qualifiée.

Sources consultées le 15 novembre 2026 : [matchers Caddy](https://caddyserver.com/docs/caddyfile/matchers),
[handle](https://caddyserver.com/docs/caddyfile/directives/handle),
[ordre de route](https://caddyserver.com/docs/caddyfile/directives/route).
