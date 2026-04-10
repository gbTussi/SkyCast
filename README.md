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

- Docker Desktop instalado e em execucao.

1. Na raiz do projeto, defina a chave TomTom no terminal atual (PowerShell):

```powershell
$env:TOMTOM_API_KEY="SUA_CHAVE_TOMTOM"
```

2. Suba o backend:

```powershell
docker compose up -d --build
```

3. Verifique se esta saudavel:

- Health: http://localhost:8081/health
- Swagger UI: http://localhost:8081/docs
- OpenAPI: http://localhost:8081/openapi.yaml

4. Para ver logs:

```powershell
docker compose logs -f backend
```

5. Para parar:

```powershell
docker compose down
```

Observacoes:

- O compose expoe o backend na porta 8081.
- Sem TOMTOM_API_KEY, o endpoint /api/traffic retorna erro 500.

## Backend: rodar sem Docker (opcional)

```powershell
cd backend
dart pub get
copy .env.example .env
dart run bin/server.dart
```

Padrao no backend local: 127.0.0.1:8081 (com .env do backend).

## Frontend Flutter: como rodar apontando para o backend Docker

Como o backend no Docker roda em localhost:8081 e o emulador Android enxerga localhost do host como 10.0.2.2, rode assim:

```powershell
flutter pub get
flutter run -d emulator-5554 --dart-define=BACKEND_BASE_URL=http://10.0.2.2:8081
```

Sem --dart-define, o app usa valor padrao interno (10.0.2.2:8080).

## Endpoints do backend

- GET /health
- GET /api/geocode?name=Campinas&count=1&lang=pt
- GET /api/reverse?lat=-22.9&lon=-43.2&lang=pt
- GET /api/route?fromLat=-23.5&fromLon=-46.6&toLat=-22.9&toLon=-43.2
- GET /api/weather?lat=-23.5&lon=-46.6&timezone=auto
- GET /api/traffic?lat=-23.5&lon=-46.6

## Troubleshooting rapido

- docker compose up falha:
   - verifique se Docker Desktop esta ativo.
   - confira se a porta 8081 nao esta em uso.
   - rode docker compose logs -f backend para detalhe do erro.
- App sem dados de rota/clima:
   - confirme backend em http://localhost:8081/health.
   - confirme BACKEND_BASE_URL no flutter run.
- Trafego indisponivel:
   - confirme TOMTOM_API_KEY no ambiente do compose.
