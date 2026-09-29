# Importer des rapports CSV

Dans **Tous les rapports**, utiliser **Importer des rapports…** et sélectionner un ou plusieurs CSV exportés par NetworkPortEval. Le champ **Ordinateur source (facultatif)** s’applique aux fichiers sélectionnés.

Les rapports sont enregistrés dans le dossier de rapports courant. Le badge **Importé** distingue leurs résultats des tests locaux. La vue d’ensemble présente le fichier source, la date d’import, le nom d’ordinateur renseigné et les métadonnées réseau originales. L’import ne lance aucun test réseau.

Les CSV historiques anglais ou français sont acceptés. Les statuts traduits dans les langues prises en charge sont normalisés. Les nouveaux CSV comportent un identifiant de rapport et une version de format. Les doublons sont détectés par cet identifiant ou, pour les anciens fichiers, par l’empreinte du contenu CSV normalisé. Deux exports différents d’un ancien rapport sans identifiant peuvent être considérés comme distincts.

Limites : 5 Mo et 10 000 lignes de résultats par fichier. Un fichier invalide n’est pas partiellement enregistré ; lors d’une sélection multiple, les autres fichiers valides peuvent être importés. Les modèles de flux ne sont pas des rapports et sont refusés ici.

Le format historique contient du contexte réseau agrégé et un résumé textuel des contrôles Internet. Ces informations sont conservées dans la provenance, sans inventer des observations réseau par tentative. Les noms et commentaires du rapport original ne sont pas traduits. Les métadonnées source sont conservées lors du réexport CSV, PDF, TXT et JSON.
