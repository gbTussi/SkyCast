# SkyCast Backend

Backend REST para o app SkyCast.

## Endpoints

- `GET /health`
- `GET /api/geocode?name=Campinas&count=1`
- `GET /api/reverse?lat=-22.9&lon=-43.2&lang=pt`
- `GET /api/route?fromLat=-23.5&fromLon=-46.6&toLat=-22.9&toLon=-43.2`
- `GET /api/weather?lat=-23.5&lon=-46.6&timezone=auto`
- `GET /api/traffic?lat=-23.5&lon=-46.6`

## Swagger

- UI: `GET /docs`
- OpenAPI spec: `GET /openapi.yaml`

## Rodando

1. `cd backend`
2. `dart pub get`
3. crie `.env` com base em `.env.example`
4. `dart run bin/server.dart`

Servidor sobe em `http://127.0.0.1:8081` com o `.env` deste projeto.

## Docker Compose

Na raiz do projeto (`C:/skycast`):

1. Configure o arquivo `.env` do backend:
	- `cd backend`
	- `copy .env.example .env`
	- edite `.env` e defina `TOMTOM_API_KEY=SUA_CHAVE_AQUI`
	- `cd ..`
2. Suba o backend:
	- `docker compose up -d --build`
3. Verifique saude:
	- `http://localhost:8081/health`

Para parar:

- `docker compose down`

## Observacoes

- A rota de transito usa `TOMTOM_API_KEY` do arquivo `backend/.env`.
- CORS habilitado para facilitar desenvolvimento local/web.
