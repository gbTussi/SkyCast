# SkyCast

SkyCast e um app Flutter para planejamento de viagens com foco em clima no trajeto.

O app calcula rota, estima passagem por cidades intermediarias e cruza ETA com previsao horaria para mostrar como o tempo deve estar em cada etapa da viagem.

## O que esta implementado hoje

- Planejamento de rota por origem e destino.
- Mapa com rota usando OpenStreetMap (flutter_map).
- Clima por cidade da rota com comparativo "agora x previsao no ponto".
- Dados de transito por ponto da rota (TomTom), quando a chave esta configurada.
- Login com Firebase (email/senha e Google).
- Rotas favoritas e historico local (SharedPreferences).
- Backend proprio em Dart (Shelf) para proxy das APIs externas.
- Documentacao de API com Swagger em /docs.

## Arquitetura resumida

Frontend Flutter -> Backend SkyCast (Dart Shelf) -> APIs externas:

- Open-Meteo Geocoding (busca de cidades)
- Nominatim (reverse geocoding)
- OSRM (rota)
- Open-Meteo Forecast (clima)
- TomTom Traffic (transito)

## Stack real do projeto

- Flutter + Dart
- go_router
- flutter_map + OpenStreetMap
- geolocator
- http
- Firebase Auth + Google Sign-In
- SharedPreferences
- Backend Dart com Shelf + shelf_router
- Docker / Docker Compose para o backend

## Estrutura

- app Flutter: pasta raiz
- backend Dart: [backend](backend)
- compose do backend: [docker-compose.yml](docker-compose.yml)

## Backend: como rodar com Docker

Requisitos:

1. **Clone este repositório:**
   ```bash
   git clone [https://github.com/seu-usuario/SkyCast.git](https://github.com/seu-usuario/SkyCast.git)
