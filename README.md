# 🌦️ SkyCast | Segurança Climática em Movimento

**SkyCast** é um aplicativo inteligente desenvolvido em **Flutter** que redefine a experiência de viagem ao integrar geolocalização precisa com dados meteorológicos críticos. O foco do SkyCast é a **previsibilidade**: ele não apenas diz como está o tempo, mas como o clima estará em cada etapa do seu caminho.



## 🎯 O Problema
A maioria dos aplicativos de GPS foca apenas no trânsito, ignorando que condições climáticas severas são responsáveis por grandes riscos e atrasos. O SkyCast resolve a fragmentação de dados ambientais, centralizando alertas e previsões de rota em uma interface única e intuitiva.

## ✨ Funcionalidades do MVP

- **📍 Clima Hiperlocal:** Atualização automática baseada na posição atual do usuário.
- **🛣️ Navegação Preditiva:** Planejamento de rotas com exibição do clima ponto a ponto, cruzando o horário de saída com a previsão meteorológica no trajeto.
- **⚠️ Alertas em Tempo Real:** Monitoramento de riscos naturais e avisos da Defesa Civil via Geofencing.
- **🔍 Central de Destinos:** Busca por localidades com dados sobre qualidade do ar, focos de queimadas e sazonalidade.
- **📊 SkyCast Analytics:** Painel visual de exposição a riscos e histórico de rotas salvas para decisões futuras mais inteligentes.

## 🛠️ Stack Tecnológica

- **Frontend:** [Flutter](https://flutter.dev/) (3.x)
- **Linguagem:** Dart
- **Estado:** Riverpod / BLoC
- **Mapas:** [flutter_map](https://pub.dev/packages/flutter_map) (OpenStreetMap)
- **Dados Climáticos:** [Open-Meteo API](https://open-meteo.com/) (Open Source)
- **Roteamento:** [OSRM](http://project-osrm.org/)

## 🏗️ Arquitetura de Rota (Generalizada)

O SkyCast utiliza um algoritmo de decimação de coordenadas para otimizar o consumo de dados:
1. Recebe a polilinha da rota via OSRM.
2. Seleciona *waypoints* estratégicos (ex: a cada 50km).
3. Consulta a previsão horária para cada *waypoint* baseada no ETA (Estimated Time of Arrival).
4. Renderiza marcadores climáticos dinâmicos sobre o mapa.



## 🚀 Como Executar

1. **Clone este repositório:**
   ```bash
   git clone [https://github.com/seu-usuario/SkyCast-app.git](https://github.com/seu-usuario/SkyCast-app.git)
