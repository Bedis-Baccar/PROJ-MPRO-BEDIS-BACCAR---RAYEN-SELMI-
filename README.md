# Projet de Partitionnement Robuste - MPRO 2025-2026

Ce dépôt contient les travaux pratiques et le code source réalisés dans le cadre du projet d'Optimisation du Master MPRO (2025-2026).

**Auteurs :**  Bedis BACCAR
 Rayen SELMI

**Encadrant :**  Professeur Zacharie ALES

## Description du projet

L'objectif de ce projet est l'étude et la résolution d'un **problème de partitionnement robuste** dans un graphe non orienté $G=(V,E)$. Le problème consiste à partitionner les sommets en au plus $K$ parties (de poids limité $B$) afin de minimiser le poids des arêtes à l'intérieur des parties, tout en tenant compte d'incertitudes sur les distances et les poids des sommets.

## Méthodes de résolution implémentées

Conformément au sujet, nous avons implémenté et comparé les approches suivantes :

1. **Plans coupants** (Cutting Planes)
2. **Branch-and-Cut** (via LazyCallback)
3. **Dualisation** du problème robuste
4. **Approche Heuristique** / Formulation non compacte

----
*Projet ECMA 2025-2026*
