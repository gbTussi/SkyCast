// =============================================================================
// trip.dart — SkyCast
// =============================================================================
//
// VISÃO GERAL
// -----------
// Tela de planejamento e rastreamento de viagens rodoviárias com previsão
// climática por cidade e por horário de passagem estimado.
//
// FLUXO PRINCIPAL
// ---------------
// 1. Usuário digita origem e destino.
// 2. Geocoding converte os nomes em coordenadas (Open-Meteo Geocoding API).
// 3. Rota rodoviária é obtida via OSRM, retornando polilinha + duração.
// 4. A polilinha é amostrada em N pontos distribuídos uniformemente.
// 5. Cada ponto é reverse-geocodificado (Nominatim) para descobrir a cidade.
// 6. Duplicatas e cidades muito próximas (< 8 km) são removidas.
// 7. O ETA de cada cidade é calculado proporcionalmente à distância acumulada.
// 8. A previsão horária é buscada para o horário exato de passagem (Open-Meteo
//    Forecast API), junto com os dados "agora" para comparação.
// 9. Durante a viagem, o GPS do dispositivo atualiza o status de cada cidade
//    (upcoming → current → passed) em tempo real.
//
// APIS UTILIZADAS
// ---------------
//  • Open-Meteo Geocoding  — geocoding de nomes → coordenadas
//  • OSRM (project-osrm)  — rota rodoviária e duração
//  • Nominatim (OSM)      — reverse geocoding coordenadas → cidade
//  • Open-Meteo Forecast  — previsão horária de clima
//
// EXEMPLOS POSTMAN
// -----------------------------------------------------------------------
//
// [1] GEOCODING — buscar coordenadas de "São Paulo"
//   GET https://geocoding-api.open-meteo.com/v1/search
//       ?name=São Paulo&count=1&language=pt&format=json
//
//   curl --location 'https://geocoding-api.open-meteo.com/v1/search?name=S%C3%A3o%20Paulo&count=1&language=pt&format=json'
//
//   Resposta relevante:
//   {
//     "results": [{
//       "name": "São Paulo",
//       "latitude": -23.5475,
//       "longitude": -46.6361,
//       "country": "Brazil"
//     }]
//   }
//
// [2] ROTA RODOVIÁRIA — São Paulo → Rio de Janeiro (OSRM)
//   Atenção: OSRM espera longitude ANTES da latitude: lng,lat
//   GET https://router.project-osrm.org/route/v1/driving/-46.6361,-23.5475;-43.1729,-22.9068
//       ?overview=full&geometries=geojson&steps=false
//
//   curl --location 'https://router.project-osrm.org/route/v1/driving/-46.6361,-23.5475;-43.1729,-22.9068?overview=full&geometries=geojson&steps=false'
//
//   Resposta relevante:
//   {
//     "routes": [{
//       "duration": 20880.5,      ← segundos (~5h48min)
//       "distance": 429523.4,     ← metros
//       "geometry": {
//         "coordinates": [[-46.636, -23.547], ..., [-43.172, -22.906]]
//       }
//     }]
//   }
//
// [3] REVERSE GEOCODING — coordenada → cidade (Nominatim)
//   GET https://nominatim.openstreetmap.org/reverse
//       ?lat=-22.5&lon=-44.1&format=json&zoom=10&accept-language=pt
//   Header obrigatório: User-Agent: SkyCastApp/1.0  ← sem isso → 403
//
//   curl --location 'https://nominatim.openstreetmap.org/reverse?lat=-22.5&lon=-44.1&format=json&zoom=10&accept-language=pt' \
//        --header 'User-Agent: SkyCastApp/1.0'
//
//   Resposta relevante:
//   {
//     "address": {
//       "city": "Volta Redonda",
//       "state": "Rio de Janeiro",
//       "country": "Brasil"
//     }
//   }
//
// [4] PREVISÃO HORÁRIA — clima por hora em Volta Redonda (Open-Meteo)
//   GET https://api.open-meteo.com/v1/forecast
//       ?latitude=-22.5&longitude=-44.1
//       &hourly=temperature_2m,apparent_temperature,precipitation_probability,
//               precipitation,weather_code,wind_speed_10m
//       &past_days=1&forecast_days=3&timezone=auto
//
//   curl --location 'https://api.open-meteo.com/v1/forecast?latitude=-22.5&longitude=-44.1&hourly=temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m&past_days=1&forecast_days=3&timezone=auto'
//
//   Resposta relevante:
//   {
//     "hourly": {
//       "time":            ["2025-04-09T00:00", "2025-04-09T01:00", ...],
//       "temperature_2m":  [22.1, 21.8, ...],
//       "weather_code":    [0, 1, ...],    ← 0=céu limpo, 61=chuva leve...
//       "precipitation_probability": [5, 10, ...]
//     }
//   }
//
// CÓDIGOS WMO (weather_code) — mapeados em _codeToCondition():
//   0        → sunny   (céu limpo)
//   1, 2, 3  → cloudy  (parcialmente nublado)
//   45, 48   → cloudy  (névoa)
//   51–67    → rainy   (garoa e chuva de intensidades variadas)
//   80–82    → rainy   (chuva de pancadas)
//   95–99    → rainy   (trovoada)
//   71–77    → cloudy  (neve — mapeado como nublado pois app foca no BR)
//
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widgets/bottom_navigation.dart';

// =============================================================================
// SECTION 1 — MODELOS DE DOMÍNIO
// =============================================================================

/// Condição climática simplificada derivada do código WMO.
/// Ver tabela completa nos comentários de cabeçalho e em [_codeToCondition].
enum WeatherCondition { sunny, cloudy, rainy }

/// Status de progresso de uma cidade durante a viagem ativa.
/// A transição é: upcoming → current → passed (nunca volta atrás).
enum CityStatus {
  upcoming, // ainda não chegou
  current, // usuário está dentro do raio [_cityArrivalRadiusKm]
  passed, // usuário já ultrapassou esta cidade
}

/// Representa uma cidade ao longo da rota com seus dados climáticos.
///
/// Cada instância carrega dois conjuntos de dados:
/// - **forecast** (sem prefixo): clima previsto para o [passTime] estimado.
/// - **current** (prefixo `current`): clima no momento da consulta (agora).
///
/// Isso permite exibir comparativos "Agora vs. Previsão" no card da cidade.
class RouteCity {
  final String city;
  final String country;
  final double lat;
  final double lng;

  // Dados previstos para o horário de passagem
  final int temperature;
  final int? apparentTemperature;
  final int? precipitationProbability;
  final double? precipitationMm;
  final double? windSpeedKmh;
  final WeatherCondition condition;

  // Dados atuais (momento da consulta) — para comparação no card
  final int? currentTemperature;
  final int? currentApparentTemperature;
  final int? currentPrecipitationProbability;
  final double? currentPrecipitationMm;
  final double? currentWindSpeedKmh;
  final WeatherCondition? currentCondition;

  final String description;

  /// Horário estimado em que o usuário passará por esta cidade.
  /// Calculado proporcionalmente à distância acumulada e à duração total da rota.
  final DateTime? passTime;

  /// Minutos desde a saída até esta cidade (ETA parcial).
  final int? etaMinutesFromStart;

  // Dados de trânsito no ponto da cidade (TomTom).
  final double? trafficFreeFlowSpeedKmh;
  final double? trafficCurrentSpeedKmh;
  final double? trafficFlowRatio;

  final bool isOrigin;
  final bool isDestination;

  const RouteCity({
    required this.city,
    this.country = 'Brasil',
    required this.lat,
    required this.lng,
    required this.temperature,
    this.currentTemperature,
    this.apparentTemperature,
    this.currentApparentTemperature,
    this.precipitationProbability,
    this.currentPrecipitationProbability,
    this.precipitationMm,
    this.currentPrecipitationMm,
    this.windSpeedKmh,
    this.currentWindSpeedKmh,
    required this.condition,
    this.currentCondition,
    required this.description,
    this.passTime,
    this.etaMinutesFromStart,
    this.trafficFreeFlowSpeedKmh,
    this.trafficCurrentSpeedKmh,
    this.trafficFlowRatio,
    this.isOrigin = false,
    this.isDestination = false,
  });

  RouteCity copyWith({
    int? temperature,
    int? currentTemperature,
    int? apparentTemperature,
    int? currentApparentTemperature,
    int? precipitationProbability,
    int? currentPrecipitationProbability,
    double? precipitationMm,
    double? currentPrecipitationMm,
    double? windSpeedKmh,
    double? currentWindSpeedKmh,
    WeatherCondition? condition,
    WeatherCondition? currentCondition,
    String? description,
    DateTime? passTime,
    int? etaMinutesFromStart,
    double? trafficFreeFlowSpeedKmh,
    double? trafficCurrentSpeedKmh,
    double? trafficFlowRatio,
    bool? isOrigin,
    bool? isDestination,
  }) {
    return RouteCity(
      city: city,
      country: country,
      lat: lat,
      lng: lng,
      temperature: temperature ?? this.temperature,
      currentTemperature: currentTemperature ?? this.currentTemperature,
      apparentTemperature: apparentTemperature ?? this.apparentTemperature,
      currentApparentTemperature:
          currentApparentTemperature ?? this.currentApparentTemperature,
      precipitationProbability:
          precipitationProbability ?? this.precipitationProbability,
      currentPrecipitationProbability: currentPrecipitationProbability ??
          this.currentPrecipitationProbability,
      precipitationMm: precipitationMm ?? this.precipitationMm,
      currentPrecipitationMm:
          currentPrecipitationMm ?? this.currentPrecipitationMm,
      windSpeedKmh: windSpeedKmh ?? this.windSpeedKmh,
      currentWindSpeedKmh: currentWindSpeedKmh ?? this.currentWindSpeedKmh,
      condition: condition ?? this.condition,
      currentCondition: currentCondition ?? this.currentCondition,
      description: description ?? this.description,
      passTime: passTime ?? this.passTime,
      etaMinutesFromStart: etaMinutesFromStart ?? this.etaMinutesFromStart,
      trafficFreeFlowSpeedKmh:
          trafficFreeFlowSpeedKmh ?? this.trafficFreeFlowSpeedKmh,
      trafficCurrentSpeedKmh:
          trafficCurrentSpeedKmh ?? this.trafficCurrentSpeedKmh,
      trafficFlowRatio: trafficFlowRatio ?? this.trafficFlowRatio,
      isOrigin: isOrigin ?? this.isOrigin,
      isDestination: isDestination ?? this.isDestination,
    );
  }
}

/// Polilinha rodoviária retornada pelo OSRM.
/// [points] são pares (lat, lng). [durationSeconds] é o tempo estimado de viagem.
class RoadRouteData {
  final List<(double, double)> points;
  final double? durationSeconds;
  const RoadRouteData({required this.points, this.durationSeconds});
}

/// Sugestão de localização retornada pelo autocomplete de geocoding.
class RouteLocationSuggestion {
  final String name;
  final String country;
  final String? admin1;
  const RouteLocationSuggestion(
      {required this.name, required this.country, this.admin1});
  String get subtitle {
    final parts = <String>[];
    if (admin1 != null && admin1!.isNotEmpty) parts.add(admin1!);
    if (country.isNotEmpty) parts.add(country);
    return parts.join(', ');
  }
}

/// Rota favorita salva pelo usuário em SharedPreferences.
class FavoriteRoute {
  final String origin;
  final String destination;
  final DateTime savedAt;

  const FavoriteRoute({
    required this.origin,
    required this.destination,
    required this.savedAt,
  });

  /// Chave única derivada do par origem–destino normalizado.
  String get key => _routePairKey(origin, destination);

  Map<String, dynamic> toJson() => {
        'origin': origin,
        'destination': destination,
        'savedAt': savedAt.toIso8601String(),
      };

  static FavoriteRoute? fromJson(Map<String, dynamic> json) {
    final o = json['origin'] as String?;
    final d = json['destination'] as String?;
    final s = json['savedAt'] as String?;
    if (o == null || d == null || s == null) return null;
    final dt = DateTime.tryParse(s);
    if (dt == null) return null;
    return FavoriteRoute(origin: o, destination: d, savedAt: dt);
  }
}

/// Registro de uma viagem concluída, persistido para o painel de analytics.
class TripRecord {
  final String id;
  final String origin;
  final String destination;
  final DateTime startedAt;
  final DateTime finishedAt;
  final List<String> cityNames;
  final double distanceKm;

  /// Estimativa de minutos em que ao menos uma cidade da rota estava chuvosa.
  /// Calculado como: qtd_cidades_chuvosas × tempo_médio_entre_paradas.
  final int rainyMinutes;

  const TripRecord({
    required this.id,
    required this.origin,
    required this.destination,
    required this.startedAt,
    required this.finishedAt,
    required this.cityNames,
    required this.distanceKm,
    required this.rainyMinutes,
  });

  int get durationMinutes => finishedAt.difference(startedAt).inMinutes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'origin': origin,
        'destination': destination,
        'startedAt': startedAt.toIso8601String(),
        'finishedAt': finishedAt.toIso8601String(),
        'cityNames': cityNames,
        'distanceKm': distanceKm,
        'rainyMinutes': rainyMinutes,
      };

  static TripRecord? fromJson(Map<String, dynamic> j) {
    try {
      return TripRecord(
        id: j['id'] as String,
        origin: j['origin'] as String,
        destination: j['destination'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String),
        finishedAt: DateTime.parse(j['finishedAt'] as String),
        cityNames: (j['cityNames'] as List<dynamic>).cast<String>(),
        distanceKm: (j['distanceKm'] as num).toDouble(),
        rainyMinutes: j['rainyMinutes'] as int,
      );
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// SECTION 2 — PERSISTÊNCIA LOCAL (SharedPreferences)
// =============================================================================

const String _tripRecordsPrefsKey = 'trip_records';
const String _favoriteRoutesPrefsKey = 'favorite_routes';
const String _unitPrefsKey = 'setting_unit';
const String _backendBaseUrl = String.fromEnvironment('BACKEND_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080');

Uri _backendUri(String path, [Map<String, String>? queryParameters]) {
  final base = Uri.parse(_backendBaseUrl);
  return base.replace(path: path, queryParameters: queryParameters);
}

/// Normaliza o par origem–destino para uso como chave de favorito.
String _routePairKey(String o, String d) =>
    '${o.trim().toLowerCase()}__${d.trim().toLowerCase()}';

Future<List<TripRecord>> _loadTripRecords() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_tripRecordsPrefsKey) ?? [];
    return list
        .map((r) => TripRecord.fromJson(jsonDecode(r) as Map<String, dynamic>))
        .whereType<TripRecord>()
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  } catch (_) {
    return [];
  }
}

Future<void> _saveTripRecord(TripRecord record) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList(_tripRecordsPrefsKey) ?? [];
    existing.add(jsonEncode(record.toJson()));
    await prefs.setStringList(_tripRecordsPrefsKey, existing);
  } catch (_) {}
}

Future<List<FavoriteRoute>> _loadFavoriteRoutes() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_favoriteRoutesPrefsKey) ?? [];
    return list
        .map((r) =>
            FavoriteRoute.fromJson(jsonDecode(r) as Map<String, dynamic>))
        .whereType<FavoriteRoute>()
        .toList()
      ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  } catch (_) {
    return [];
  }
}

Future<void> _saveFavoriteRoutes(List<FavoriteRoute> routes) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(
    _favoriteRoutesPrefsKey,
    routes.map((r) => jsonEncode(r.toJson())).toList(),
  );
}

Future<void> _clearTripRecords() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_tripRecordsPrefsKey);
}

Future<void> _clearFavoriteRoutes() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_favoriteRoutesPrefsKey);
}

// =============================================================================
// SECTION 3 — FORMATAÇÃO / UTILITÁRIOS DE EXIBIÇÃO
// =============================================================================

String _weatherLabel(WeatherCondition c) {
  if (c == WeatherCondition.sunny) return 'Ensolarado';
  if (c == WeatherCondition.rainy) return 'Chuvoso';
  return 'Nublado';
}

String _weatherEmoji(WeatherCondition c) {
  if (c == WeatherCondition.sunny) return '☀️';
  if (c == WeatherCondition.rainy) return '🌧️';
  return '☁️';
}

String _formatHour(DateTime? dt) {
  if (dt == null) return '--:--';
  return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
}

String _formatDateHour(DateTime? dt) {
  if (dt == null) return '--/-- --:--';
  return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${_formatHour(dt)}';
}

String _formatDuration(double seconds) {
  final m = (seconds / 60).round();
  final h = m ~/ 60;
  final min = m % 60;
  if (h <= 0) return '${min}min';
  if (min == 0) return '${h}h';
  return '${h}h ${min}min';
}

String _formatEtaFromMinutes(int? totalMinutes) {
  if (totalMinutes == null) return '--';
  if (totalMinutes <= 59) return '$totalMinutes min';
  final h = totalMinutes ~/ 60;
  final min = totalMinutes % 60;
  if (min == 0) return '${h}h';
  return '${h}h ${min}min';
}

bool _isDarkMode(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

Color _pageBg(BuildContext context) =>
    _isDarkMode(context) ? const Color(0xFF0B1220) : const Color(0xFFEFF6FF);

Color _surface(BuildContext context) =>
    _isDarkMode(context) ? const Color(0xFF111827) : Colors.white;

Color _surfaceAlt(BuildContext context) =>
    _isDarkMode(context) ? const Color(0xFF1F2937) : const Color(0xFFF8FAFC);

Color _border(BuildContext context) =>
    _isDarkMode(context) ? const Color(0xFF374151) : const Color(0xFFE5E7EB);

Color _textPrimary(BuildContext context) =>
    _isDarkMode(context) ? const Color(0xFFE5E7EB) : const Color(0xFF1F2937);

Color _textSecondary(BuildContext context) =>
    _isDarkMode(context) ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);

// =============================================================================
// SECTION 4 — GEOCODING (Open-Meteo Geocoding API)
// =============================================================================
// Documentação: https://open-meteo.com/en/docs/geocoding-api
//
// Exemplo Postman — busca única (usado internamente pelo app):
//   GET https://geocoding-api.open-meteo.com/v1/search
//       ?name=Campinas&count=1&language=pt&format=json
//
// Exemplo Postman — autocomplete (até 8 sugestões):
//   GET https://geocoding-api.open-meteo.com/v1/search
//       ?name=Cam&count=8&language=pt&format=json
// =============================================================================

/// Busca o primeiro resultado de geocoding para [query].
/// Retorna o objeto completo da API (name, latitude, longitude, country, admin1…)
/// ou null em caso de falha ou ausência de resultados.
Future<Map<String, dynamic>?> _searchLocation(String query) async {
  try {
    final uri = _backendUri('/api/geocode', {
      'name': query,
      'count': '1',
      'lang': 'pt',
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return null;
    final results = (jsonDecode(r.body) as Map?)?['results'] as List?;
    if (results == null || results.isEmpty) return null;
    return results.first as Map<String, dynamic>?;
  } catch (_) {
    return null;
  }
}

/// Busca até 8 sugestões de geocoding para [query] — usado pelo autocomplete.
Future<List<RouteLocationSuggestion>> _searchLocations(String query) async {
  try {
    final uri = _backendUri('/api/geocode', {
      'name': query,
      'count': '8',
      'lang': 'pt',
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) return [];
    final results = (jsonDecode(r.body) as Map?)?['results'] as List? ?? [];
    return results
        .map((m) => RouteLocationSuggestion(
              name: (m as Map)['name'] as String? ?? '',
              country: m['country'] as String? ?? '',
              admin1: m['admin1'] as String?,
            ))
        .where((s) => s.name.isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

// =============================================================================
// SECTION 5 — ROTA RODOVIÁRIA (OSRM)
// =============================================================================
// API pública: https://router.project-osrm.org
// Documentação: http://project-osrm.org/docs/v5.24.0/api/
//
// ⚠️ OSRM recebe coordenadas no formato lng,lat (longitude PRIMEIRO).
//    O app inverte para (lat, lng) após receber a resposta GeoJSON.
//
// Exemplo Postman — rota São Paulo → Rio de Janeiro:
//   GET https://router.project-osrm.org/route/v1/driving/-46.6361,-23.5475;-43.1729,-22.9068
//       ?overview=full&geometries=geojson&steps=false
//
// Parâmetros relevantes:
//   overview=full      → polilinha completa (não simplificada)
//   geometries=geojson → coordenadas em GeoJSON [[lng,lat], ...]
//   steps=false        → sem turn-by-turn (reduz payload)
// =============================================================================

/// Busca a polilinha rodoviária e duração entre dois pontos via OSRM.
///
/// Tenta a rota direta; em caso de falha o chamador tenta a rota invertida.
/// Retorna [RoadRouteData] com lista vazia se OSRM não responder.
Future<RoadRouteData> _fetchRoadRouteData(
    double lat1, double lng1, double lat2, double lng2) async {
  try {
    final uri = _backendUri('/api/route', {
      'fromLat': lat1.toString(),
      'fromLon': lng1.toString(),
      'toLat': lat2.toString(),
      'toLon': lng2.toString(),
    });
    final r = await http.get(uri).timeout(const Duration(seconds: 12));
    if (r.statusCode != 200) return const RoadRouteData(points: []);

    final body = jsonDecode(r.body) as Map<String, dynamic>?;
    final first =
        (body?['routes'] as List?)?.firstOrNull as Map<String, dynamic>?;
    if (first == null) return const RoadRouteData(points: []);

    final coords = (first['geometry'] as Map?)?['coordinates'] as List?;
    if (coords == null || coords.length < 2) {
      return RoadRouteData(
          points: const [],
          durationSeconds: (first['duration'] as num?)?.toDouble());
    }

    // GeoJSON retorna [lng, lat] — invertemos para (lat, lng)
    final points = coords
        .map((p) {
          final pair = p as List;
          final lng = (pair[0] as num?)?.toDouble();
          final lat = (pair[1] as num?)?.toDouble();
          return lat != null && lng != null ? (lat, lng) : null;
        })
        .whereType<(double, double)>()
        .toList();

    return RoadRouteData(
        points: points,
        durationSeconds: (first['duration'] as num?)?.toDouble());
  } catch (_) {
    return const RoadRouteData(points: []);
  }
}

// =============================================================================
// SECTION 6 — CÁLCULO DE DISTÂNCIA (Haversine)
// =============================================================================

/// Calcula a distância em km entre dois pontos geográficos usando Haversine.
///
/// Fórmula: d = 2R × arcsin(√(sin²(Δlat/2) + cos(lat1)·cos(lat2)·sin²(Δlng/2)))
/// Erro típico < 0,5% para distâncias até ~500 km.
double _distanceKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0; // raio médio da Terra em km
  final dLat = (lat2 - lat1) * pi / 180;
  final dLng = (lng2 - lng1) * pi / 180;
  final a = sin(dLat / 2) * sin(dLat / 2) +
      cos(lat1 * pi / 180) *
          cos(lat2 * pi / 180) *
          sin(dLng / 2) *
          sin(dLng / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

/// Soma a distância Haversine entre todos os pontos consecutivos de uma polilinha.
double _polylineDistanceKm(List<(double, double)> points) {
  if (points.length < 2) return 0;
  double total = 0;
  for (int i = 1; i < points.length; i++) {
    total += _distanceKm(
        points[i - 1].$1, points[i - 1].$2, points[i].$1, points[i].$2);
  }
  return total;
}

// =============================================================================
// SECTION 7 — INTERPOLAÇÃO E AMOSTRAGEM DE PONTOS
// =============================================================================

/// Gera [count] pontos linearmente interpolados entre dois pontos geográficos.
///
/// Usado como FALLBACK quando o OSRM não retorna uma polilinha válida.
/// Não segue estradas — traça uma linha reta entre origem e destino.
List<(double, double)> _interpolatePoints(
    double lat1, double lng1, double lat2, double lng2, int count) {
  if (count < 2) return [(lat1, lng1)];
  return List.generate(count, (i) {
    final t = i / (count - 1);
    return (lat1 + (lat2 - lat1) * t, lng1 + (lng2 - lng1) * t);
  });
}

/// Amostra [count] pontos IGUALMENTE ESPAÇADOS ao longo de uma polilinha real.
///
/// Algoritmo:
/// 1. Calcula a distância total da polilinha.
/// 2. Gera [count] alvos de distância espaçados uniformemente (0, total/(n-1), ..., total).
/// 3. Percorre os segmentos somando distâncias; quando alcança um alvo,
///    interpola linearmente a posição exata dentro do segmento.
/// 4. Garante que o primeiro e o último ponto são exatamente a origem e o destino.
///
/// Isso distribui as consultas de reverse geocoding uniformemente ao longo
/// da rota, independentemente da densidade dos pontos OSRM.
List<(double, double)> _samplePolylineByCount(
    List<(double, double)> points, int count) {
  if (points.isEmpty) return [];
  if (count <= 1 || points.length == 1) return [points.first];
  final total = _polylineDistanceKm(points);
  if (total <= 0) return [points.first, points.last];

  final targets = List.generate(count, (i) => (total * i) / (count - 1));
  final sampled = <(double, double)>[];
  int seg = 0;
  double walked = 0;

  for (final target in targets) {
    while (seg < points.length - 1) {
      final a = points[seg];
      final b = points[seg + 1];
      final segDist = _distanceKm(a.$1, a.$2, b.$1, b.$2);
      if (walked + segDist >= target || seg == points.length - 2) {
        final remain = target - walked;
        // t ∈ [0,1]: posição proporcional dentro do segmento atual
        final t = segDist <= 0 ? 0.0 : (remain / segDist).clamp(0.0, 1.0);
        sampled.add((a.$1 + (b.$1 - a.$1) * t, a.$2 + (b.$2 - a.$2) * t));
        break;
      }
      walked += segDist;
      seg++;
    }
  }

  if (sampled.isEmpty) return [points.first, points.last];
  // Ancora início e fim nos pontos originais para evitar desvio de arredondamento
  sampled[0] = points.first;
  sampled[sampled.length - 1] = points.last;
  return sampled;
}

/// Determina quantos pontos de amostragem usar de acordo com a distância total.
/// Rotas mais longas recebem mais pontos para melhor cobertura intermediária.
int _sampleCount(double distKm) {
  if (distKm < 50) return 6;
  if (distKm < 150) return 10;
  if (distKm < 400) return 14;
  if (distKm < 800) return 20;
  return 26;
}

// =============================================================================
// SECTION 8 — REVERSE GEOCODING (Nominatim / OpenStreetMap)
// =============================================================================
// API: https://nominatim.openstreetmap.org/reverse
// Política de uso: máximo 1 req/segundo — controlado por [_queueNominatimRequest].
//
// Exemplo Postman — coordenada entre SP e RJ:
//   GET https://nominatim.openstreetmap.org/reverse
//       ?lat=-22.5&lon=-44.1&format=json&zoom=10&accept-language=pt
//   Header: User-Agent: SkyCastApp/1.0   ← OBRIGATÓRIO
//
// Zoom 10 = nível de município. Fallback para 8 (cidade maior) e 6 (região).
// =============================================================================

/// Intervalo mínimo entre requisições ao Nominatim (política de uso: 1 req/s).
const _nominatimMinInterval = Duration(milliseconds: 1200);

/// Cache de resultados por coordenada aproximada (3 casas decimais ≈ 111 m).
final Map<String, RouteCity?> _nearestCityCache = {};

/// Fila serial que garante no máximo 1 requisição simultânea ao Nominatim.
Future<void> _nominatimQueue = Future.value();
DateTime _lastNominatimRequestAt = DateTime.fromMillisecondsSinceEpoch(0);

String _coordCacheKey(double lat, double lng) =>
    '${(lat * 1000).round() / 1000},${(lng * 1000).round() / 1000}';

/// Enfileira uma requisição ao Nominatim respeitando o rate limit de 1 req/s.
Future<T> _queueNominatimRequest<T>(Future<T> Function() request) {
  final completer = Completer<T>();
  _nominatimQueue = _nominatimQueue.then((_) async {
    final elapsed = DateTime.now().difference(_lastNominatimRequestAt);
    if (elapsed < _nominatimMinInterval) {
      await Future.delayed(_nominatimMinInterval - elapsed);
    }
    _lastNominatimRequestAt = DateTime.now();
    try {
      completer.complete(await request());
    } catch (e, st) {
      completer.completeError(e, st);
    }
  });
  return completer.future;
}

/// Retorna a cidade mais próxima de [lat],[lng] via reverse geocoding,
/// com cache por coordenada e rate-limiting automático.
Future<RouteCity?> _nearestCity(double lat, double lng) async {
  final k = _coordCacheKey(lat, lng);
  if (_nearestCityCache.containsKey(k)) return _nearestCityCache[k];
  final city =
      await _queueNominatimRequest(() => _reverseGeocodeCity(lat, lng));
  _nearestCityCache[k] = city;
  return city;
}

/// Chamada bruta ao Nominatim. Tenta zoom 10 → 8 → 6 como fallback.
Future<RouteCity?> _reverseGeocodeCity(double lat, double lng) async {
  for (final zoom in ['10', '8', '6']) {
    try {
      final uri = _backendUri('/api/reverse', {
        'lat': lat.toString(),
        'lon': lng.toString(),
        'zoom': zoom,
        'lang': 'pt',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) continue;
      final data = jsonDecode(res.body) as Map<String, dynamic>?;
      final address = data?['address'] as Map<String, dynamic>?;
      if (address == null) continue;
      // Prioridade de campos: city > town > village > municipality
      final name = address['city'] as String? ??
          address['town'] as String? ??
          address['village'] as String? ??
          address['municipality'] as String?;
      if (name == null) continue;
      return RouteCity(
        city: name,
        country: address['country'] as String? ?? 'Brasil',
        lat: double.tryParse(data?['lat'] as String? ?? '') ?? lat,
        lng: double.tryParse(data?['lon'] as String? ?? '') ?? lng,
        temperature: 0,
        condition: WeatherCondition.cloudy,
        description: name,
      );
    } catch (_) {
      continue;
    }
  }
  return null;
}

// =============================================================================
// SECTION 9 — ORQUESTRAÇÃO DAS CIDADES DA ROTA
// =============================================================================

/// Pipeline principal: geocodifica origem/destino → obtém polilinha OSRM →
/// amostra pontos → reverse geocoding → remove duplicatas → retorna lista.
Future<List<RouteCity>> _getRouteCities(String from, String to) async {
  // 1. Geocodificar origem e destino
  final oLoc = await _searchLocation(from);
  final dLoc = await _searchLocation(to);
  final oLat = (oLoc?['latitude'] as num?)?.toDouble() ?? 0.0;
  final oLng = (oLoc?['longitude'] as num?)?.toDouble() ?? 0.0;
  final dLat = (dLoc?['latitude'] as num?)?.toDouble() ?? 0.0;
  final dLng = (dLoc?['longitude'] as num?)?.toDouble() ?? 0.0;
  final oName = (oLoc?['name'] as String?) ?? from;
  final dName = (dLoc?['name'] as String?) ?? to;
  final oCountry = oLoc?['country'] as String? ?? 'Brasil';
  final dCountry = dLoc?['country'] as String? ?? 'Brasil';

  // 2. Obter polilinha rodoviária (tenta direta, depois invertida como fallback)
  var roadData = await _fetchRoadRouteData(oLat, oLng, dLat, dLng);
  if (roadData.points.length < 2) {
    final rev = await _fetchRoadRouteData(dLat, dLng, oLat, oLng);
    if (rev.points.length >= 2) {
      roadData = RoadRouteData(
          points: rev.points.reversed.toList(),
          durationSeconds: rev.durationSeconds);
    }
  }

  // 3. Amostrar pontos ao longo da rota (ou interpolar se não houver polilinha)
  final rr = roadData.points;
  final distKm = rr.length > 1
      ? _polylineDistanceKm(rr)
      : _distanceKm(oLat, oLng, dLat, dLng);
  final n = _sampleCount(distKm);
  final pts = rr.length > 1
      ? _samplePolylineByCount(rr, n)
      : _interpolatePoints(oLat, oLng, dLat, dLng, n);

  // 4. Reverse geocoding de cada ponto amostrado (serializado com rate-limit)
  final raw = <RouteCity>[];
  for (final p in pts) {
    final city = await _nearestCity(p.$1, p.$2);
    if (city != null) raw.add(city);
  }

  // 5. Remover duplicatas por nome e por proximidade (< 8 km)
  final seen = <String>{};
  final unique = <RouteCity>[];
  for (final city in raw) {
    if (seen.contains(city.city)) continue;
    if (unique.any((e) => _distanceKm(e.lat, e.lng, city.lat, city.lng) < 8.0))
      continue;
    seen.add(city.city);
    unique.add(city);
  }

  // 6. Fallback: se nenhuma cidade foi encontrada, retorna só origem e destino
  if (unique.isEmpty) {
    return [
      RouteCity(
          city: oName,
          country: oCountry,
          lat: oLat,
          lng: oLng,
          temperature: 0,
          condition: WeatherCondition.cloudy,
          description: 'Origem: $oName',
          isOrigin: true),
      RouteCity(
          city: dName,
          country: dCountry,
          lat: dLat,
          lng: dLng,
          temperature: 0,
          condition: WeatherCondition.cloudy,
          description: 'Destino: $dName',
          isDestination: true),
    ];
  }

  // 7. Forçar origem e destino nos extremos da lista
  final result = List<RouteCity>.from(unique);
  result[0] = RouteCity(
      city: oName,
      country: oCountry,
      lat: oLat,
      lng: oLng,
      temperature: 0,
      condition: WeatherCondition.cloudy,
      description: 'Origem: $oName',
      isOrigin: true);
  result[result.length - 1] = RouteCity(
      city: dName,
      country: dCountry,
      lat: dLat,
      lng: dLng,
      temperature: 0,
      condition: WeatherCondition.cloudy,
      description: 'Destino: $dName',
      isDestination: true);
  return result;
}

// =============================================================================
// SECTION 10 — PREVISÃO CLIMÁTICA HORÁRIA (Open-Meteo Forecast API)
// =============================================================================
// Documentação: https://open-meteo.com/en/docs
//
// Exemplo Postman — previsão horária para Volta Redonda/RJ:
//   GET https://api.open-meteo.com/v1/forecast
//       ?latitude=-22.5239&longitude=-44.1044
//       &hourly=temperature_2m,apparent_temperature,
//               precipitation_probability,precipitation,
//               weather_code,wind_speed_10m
//       &past_days=1&forecast_days=3&timezone=auto
//
// Resposta relevante:
//   {
//     "hourly": {
//       "time":   ["2025-04-09T00:00", "2025-04-09T01:00", ...],
//       "temperature_2m": [22.1, 21.5, ...],
//       "weather_code":   [0, 3, 61, ...]
//     }
//   }
//
// Estratégia de busca do índice correto:
//   1. Arredonda [passTime] para a hora mais próxima (±30 min).
//   2. Busca o ISO timestamp exato no array "time".
//   3. Se não encontrar, usa o índice com menor diferença absoluta.
//   4. O mesmo processo é repetido para DateTime.now() → dados "current".
// =============================================================================

/// Converte código WMO em [WeatherCondition].
/// Referência: https://open-meteo.com/en/docs#weathervariables
WeatherCondition _codeToCondition(int? code) {
  if (code == null) return WeatherCondition.cloudy;
  if (code == 0) return WeatherCondition.sunny;
  if ([1, 2, 3, 45, 48].contains(code)) return WeatherCondition.cloudy;
  if ([51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99]
      .contains(code)) return WeatherCondition.rainy;
  return WeatherCondition.cloudy;
}

/// Arredonda para a hora cheia mais próxima (≥ 30 min → hora seguinte).
DateTime _roundToNearestHour(DateTime dt) {
  final rounded = DateTime(dt.year, dt.month, dt.day, dt.hour);
  return dt.minute >= 30 ? rounded.add(const Duration(hours: 1)) : rounded;
}

/// Estima a duração total da rota em segundos assumindo 75 km/h de média.
/// Usado quando o OSRM não retorna a duração.
double _estimatedDurationSecondsFromDistance(double distanceKm) =>
    ((distanceKm / 75.0) * 3600).clamp(900, 60 * 60 * 30);

/// Busca a previsão horária para [city] no horário [passTime] e também
/// os dados "agora" (para o comparativo Agora vs Previsão no card).
///
/// Usa janela de past_days=1 + forecast_days=3 para garantir que o [passTime]
/// estará dentro do range independentemente do fuso horário.
///
/// Fallback: se o endpoint horário falhar, usa /v1/forecast?current=... .
Future<RouteCity> _fetchHourlyWeatherForCity(
    RouteCity city, DateTime passTime) async {
  Future<http.Response?> retry(Uri uri) async {
    for (int i = 0; i < 2; i++) {
      try {
        final r = await http.get(uri).timeout(const Duration(seconds: 10));
        if (r.statusCode == 200) return r;
      } catch (_) {}
      if (i < 1) await Future.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  try {
    final url = _backendUri('/api/weather', {
      'lat': city.lat.toString(),
      'lon': city.lng.toString(),
      'past_days': '1', // garante cobertura retroativa
      'forecast_days': '3', // 72h para frente
      'timezone': 'auto',
    });

    final response = await retry(url);

    // ── FALLBACK: usa endpoint "current" se o horário falhar ──────────────
    if (response == null) {
      final fb = _backendUri('/api/weather', {
        'lat': city.lat.toString(),
        'lon': city.lng.toString(),
        'timezone': 'auto',
      });
      final fbR = await retry(fb);
      if (fbR == null) return city;
      final cur = (jsonDecode(fbR.body) as Map?)?['current'] as Map?;
      if (cur == null) return city;
      final t = (cur['temperature_2m'] as num?)?.round() ?? city.temperature;
      final cond = _codeToCondition((cur['weather_code'] as num?)?.round());
      final pfx = city.isOrigin
          ? 'Origem'
          : city.isDestination
              ? 'Destino'
              : 'Passagem';
      return city.copyWith(
        passTime: passTime,
        temperature: t,
        currentTemperature: t,
        apparentTemperature: (cur['apparent_temperature'] as num?)?.round(),
        currentApparentTemperature:
            (cur['apparent_temperature'] as num?)?.round(),
        precipitationMm: (cur['precipitation'] as num?)?.toDouble(),
        currentPrecipitationMm: (cur['precipitation'] as num?)?.toDouble(),
        windSpeedKmh: (cur['wind_speed_10m'] as num?)?.toDouble(),
        currentWindSpeedKmh: (cur['wind_speed_10m'] as num?)?.toDouble(),
        condition: cond,
        currentCondition: cond,
        description:
            '$pfx · ${_weatherLabel(cond)} (atual) às ${_formatHour(passTime)}',
      );
    }

    // ── Localiza o índice horário mais próximo de passTime ─────────────────
    final hourly = (jsonDecode(response.body) as Map?)?['hourly'] as Map?;
    final times = (hourly?['time'] as List?)?.cast<String>() ?? [];
    if (times.isEmpty) return city;

    int _findIdx(DateTime target) {
      final iso = target.toIso8601String().substring(0, 13) + ':00';
      final exact = times.indexOf(iso);
      if (exact >= 0) return exact;
      // Busca o mais próximo por diferença absoluta de minutos
      int bestIdx = 0;
      int? bestDelta;
      for (int i = 0; i < times.length; i++) {
        final parsed = DateTime.tryParse(times[i]);
        if (parsed == null) continue;
        final delta = parsed.difference(target).inMinutes.abs();
        if (bestDelta == null || delta < bestDelta) {
          bestDelta = delta;
          bestIdx = i;
        }
      }
      return bestIdx;
    }

    final idx = _findIdx(_roundToNearestHour(passTime));
    final nowIdx = _findIdx(_roundToNearestHour(DateTime.now()));

    int? ai(String k, int i) {
      final v = hourly?[k] as List?;
      return (v != null && i < v.length) ? (v[i] as num?)?.round() : null;
    }

    double? ad(String k, int i) {
      final v = hourly?[k] as List?;
      return (v != null && i < v.length) ? (v[i] as num?)?.toDouble() : null;
    }

    final pfx = city.isOrigin
        ? 'Origem'
        : city.isDestination
            ? 'Destino'
            : 'Passagem';
    final cond = _codeToCondition(ai('weather_code', idx));

    return city.copyWith(
      passTime: passTime,
      // Dados previstos para o horário de passagem
      temperature: ai('temperature_2m', idx) ?? city.temperature,
      apparentTemperature: ai('apparent_temperature', idx),
      precipitationProbability: ai('precipitation_probability', idx),
      precipitationMm: ad('precipitation', idx),
      windSpeedKmh: ad('wind_speed_10m', idx),
      condition: cond,
      // Dados atuais (para comparativo no card)
      currentTemperature: ai('temperature_2m', nowIdx),
      currentApparentTemperature: ai('apparent_temperature', nowIdx),
      currentPrecipitationProbability: ai('precipitation_probability', nowIdx),
      currentPrecipitationMm: ad('precipitation', nowIdx),
      currentWindSpeedKmh: ad('wind_speed_10m', nowIdx),
      currentCondition: _codeToCondition(ai('weather_code', nowIdx)),
      description: '$pfx · ${_weatherLabel(cond)} às ${_formatHour(passTime)}',
    );
  } catch (_) {
    return city;
  }
}

// =============================================================================
// SECTION 11 — ETA E ENRIQUECIMENTO COM CLIMA
// =============================================================================

/// Calcula o ETA de cada cidade (proporcional à distância acumulada)
/// e busca a previsão climática horária para cada uma em paralelo.
///
/// Algoritmo de ETA:
///   passTime(i) = departureTime + effectiveDuration × (cumKm[i] / totalKm)
///
/// Onde effectiveDuration é a duração OSRM (ou estimada por 75 km/h).
/// O semáforo limita a 3 chamadas simultâneas ao Open-Meteo.
Future<List<RouteCity>> _enrichCitiesWithEtaAndHourlyWeather(
  List<RouteCity> cities, {
  required DateTime departureTime,
  double? routeDurationSeconds,
}) async {
  if (cities.isEmpty) return [];
  if (cities.length == 1) {
    return [
      await _fetchHourlyWeatherForCity(cities.first, departureTime)
          .then((c) => c.copyWith(etaMinutesFromStart: 0))
    ];
  }

  // Distâncias acumuladas entre cidades consecutivas (Haversine ponto a ponto)
  final cumKm = <double>[0.0];
  for (int i = 1; i < cities.length; i++) {
    cumKm.add(cumKm.last +
        _distanceKm(cities[i - 1].lat, cities[i - 1].lng, cities[i].lat,
            cities[i].lng));
  }
  final totalKm = cumKm.last;
  final effDur = routeDurationSeconds ??
      _estimatedDurationSecondsFromDistance(totalKm <= 0 ? 50 : totalKm);

  final withEta = <RouteCity>[];
  for (int i = 0; i < cities.length; i++) {
    final ratio = totalKm <= 0 ? i / (cities.length - 1) : cumKm[i] / totalKm;
    final sec = (effDur * ratio).round();
    withEta.add(cities[i].copyWith(
      passTime: departureTime.add(Duration(seconds: sec)),
      etaMinutesFromStart: (sec / 60).round(),
    ));
  }

  // Semáforo: máximo 3 requisições simultâneas ao Open-Meteo
  final sem = _Semaphore(3);
  return Future.wait(
    withEta.map((city) async {
      await sem.acquire();
      try {
        return await _fetchHourlyWeatherForCity(
            city, city.passTime ?? departureTime);
      } finally {
        sem.release();
      }
    }),
  );
}

// =============================================================================
// SECTION 12 — UTILITÁRIOS INTERNOS
// =============================================================================

/// Semáforo simples baseado em [Completer] para limitar concorrência HTTP
/// sem dependências externas (como o pacote `pool`).
class _Semaphore {
  final int maxCount;
  int _count = 0;
  final _queue = <Completer<void>>[];
  _Semaphore(this.maxCount);
  Future<void> acquire() async {
    if (_count < maxCount) {
      _count++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _count--;
    }
  }
}

/// Raio em km para considerar que o usuário "chegou" em uma cidade.
/// 15 km foi escolhido para tolerar GPS impreciso em rodovias rurais.
const double _cityArrivalRadiusKm = 15.0;

// =============================================================================
// SECTION 13 — WIDGETS (Loading, StatusBadge, CityCard, SelectionChip)
// =============================================================================

class _RouteLoadingCard extends StatefulWidget {
  final String message;
  const _RouteLoadingCard({required this.message});
  @override
  State<_RouteLoadingCard> createState() => _RouteLoadingCardState();
}

class _RouteLoadingCardState extends State<_RouteLoadingCard>
    with TickerProviderStateMixin {
  static const _icons = [
    Icons.directions_car,
    Icons.add_road,
    Icons.wb_sunny,
    Icons.cloud,
    Icons.grain,
    Icons.bolt
  ];
  static const _msgs = [
    'Calculando rota...',
    'Gerando pontos da rota...',
    'Consultando dados climáticos...',
    'Buscando previsão por horário...',
    'Quase lá...'
  ];
  late final AnimationController _ic, _fc, _mc;
  late final Animation<double> _fa, _mf;
  int _ii = 0, _mi = 0;
  @override
  void initState() {
    super.initState();
    _fc = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400));
    _fa = CurvedAnimation(parent: _fc, curve: Curves.easeInOut);
    _mc = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 350));
    _mf = CurvedAnimation(parent: _mc, curve: Curves.easeInOut);
    _ic = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          _fc.forward(from: 0).then((_) {
            if (!mounted) return;
            setState(() => _ii = (_ii + 1) % _icons.length);
            _fc.reverse();
          });
          if (_ii % 2 == 0) {
            _mc.forward(from: 0).then((_) {
              if (!mounted) return;
              setState(() => _mi = (_mi + 1) % _msgs.length);
              _mc.reverse();
            });
          }
          _ic.forward(from: 0);
        }
      });
    _ic.forward();
  }

  @override
  void dispose() {
    _ic.dispose();
    _fc.dispose();
    _mc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.07),
                  blurRadius: 12,
                  offset: const Offset(0, 3))
            ]),
        child: Column(children: [
          AnimatedBuilder(
              animation: _fa,
              builder: (_, __) => Opacity(
                  opacity: (1 - _fa.value).clamp(0.0, 1.0),
                  child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                          color: const Color(0xFFEFF6FF),
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: const Color(0xFFBFDBFE), width: 1.5)),
                      child: Icon(_icons[_ii],
                          size: 36, color: const Color(0xFF2563EB))))),
          const SizedBox(height: 20),
          Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_icons.length, (i) {
                final a = i == _ii;
                return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 5),
                    width: a ? 28 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                        color: a
                            ? const Color(0xFF2563EB)
                            : const Color(0xFFBFDBFE),
                        borderRadius: BorderRadius.circular(4)));
              })),
          const SizedBox(height: 20),
          AnimatedBuilder(
              animation: _mf,
              builder: (_, __) => Opacity(
                  opacity: (1 - _mf.value).clamp(0.0, 1.0),
                  child: Text(_msgs[_mi],
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1E40AF)),
                      textAlign: TextAlign.center))),
          const SizedBox(height: 6),
          const Text(
              'Isso pode levar alguns segundos\ndependendo do tamanho da rota.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
        ]),
      );
}

class _StatusBadge extends StatelessWidget {
  final CityStatus status;
  const _StatusBadge(this.status);
  @override
  Widget build(BuildContext ctx) {
    final (lbl, bg, fg, ic) = switch (status) {
      CityStatus.current => (
          'Você está aqui',
          const Color(0xFFFEF3C7),
          const Color(0xFF92400E),
          Icons.navigation
        ),
      CityStatus.passed => (
          'Cidade passada',
          const Color(0xFFF0FDF4),
          const Color(0xFF166534),
          Icons.check_circle
        ),
      CityStatus.upcoming => (
          'Próxima parada',
          const Color(0xFFEFF6FF),
          const Color(0xFF1E40AF),
          Icons.arrow_forward
        ),
    };
    return Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration:
            BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(lbl,
              style: TextStyle(
                  fontSize: 10, color: fg, fontWeight: FontWeight.w600))
        ]));
  }
}

class _RouteCityCard extends StatefulWidget {
  final RouteCity city;
  final CityStatus? tripStatus;
  final String tempUnit;
  const _RouteCityCard(
      {required this.city, this.tripStatus, required this.tempUnit});
  @override
  State<_RouteCityCard> createState() => _RouteCityCardState();
}

class _RouteCityCardState extends State<_RouteCityCard>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late AnimationController _pc;
  late Animation<double> _pa;
  @override
  void initState() {
    super.initState();
    _pc = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _pa = Tween<double>(begin: 0.85, end: 1.0)
        .animate(CurvedAnimation(parent: _pc, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final city = widget.city;
    final dark = _isDarkMode(context);
    final status = widget.tripStatus;
    final isCur = status == CityStatus.current;
    final isPas = status == CityStatus.passed;
    final isKey = city.isOrigin || city.isDestination;
    final dc = isPas
        ? const Color(0xFF6B7280)
        : isCur
            ? const Color(0xFFF59E0B)
            : city.isOrigin
                ? const Color(0xFF1D4ED8)
                : city.isDestination
                    ? const Color(0xFF065F46)
                    : const Color(0xFF3B82F6);

    Widget card = AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
            color: isPas
                ? (dark ? const Color(0xFF0F172A) : const Color(0xFFF9FAFB))
                : isCur
                    ? (dark ? const Color(0xFF1E293B) : const Color(0xFFFFFBEB))
                    : _surface(context),
            borderRadius: BorderRadius.circular(16),
            boxShadow: isCur
                ? [
                    BoxShadow(
                        color: const Color(0xFFF59E0B).withOpacity(0.25),
                        blurRadius: 12,
                        offset: const Offset(0, 4))
                  ]
                : [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.07),
                        blurRadius: 8,
                        offset: const Offset(0, 2))
                  ],
            border: Border.all(
                color: isPas
                    ? _border(context)
                    : isCur
                        ? const Color(0xFFF59E0B)
                        : (isKey ? dc.withOpacity(0.35) : _border(context)),
                width: isCur ? 2 : 1)),
        child: Opacity(
            opacity: isPas ? 0.65 : 1.0,
            child: Column(children: [
              InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(children: [
                        if (isPas)
                          const Icon(Icons.check_circle,
                              size: 20, color: Color(0xFF6B7280))
                        else if (isCur)
                          AnimatedBuilder(
                              animation: _pa,
                              builder: (_, __) => Transform.scale(
                                  scale: _pa.value,
                                  child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                          color: const Color(0xFFF59E0B),
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                                color: const Color(0xFFF59E0B)
                                                    .withOpacity(0.5),
                                                blurRadius: 8)
                                          ],
                                          border: Border.all(
                                              color: Colors.white, width: 2)))))
                        else
                          Container(
                              width: isKey ? 18 : 12,
                              height: isKey ? 18 : 12,
                              decoration: BoxDecoration(
                                  color: dc,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.white, width: 2))),
                        const SizedBox(width: 12),
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                              Row(children: [
                                Flexible(
                                    child: Text(city.city,
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 15,
                                            color: isPas
                                                ? _textSecondary(context)
                                                : city.isOrigin
                                                    ? const Color(0xFF1E40AF)
                                                    : city.isDestination
                                                        ? const Color(
                                                            0xFF064E3B)
                                                        : _textPrimary(context),
                                            decoration: isPas
                                                ? TextDecoration.lineThrough
                                                : null))),
                                if (city.isOrigin)
                                  _badge('Origem', const Color(0xFFDBEAFE),
                                      const Color(0xFF1E40AF)),
                                if (city.isDestination)
                                  _badge('Destino', const Color(0xFFD1FAE5),
                                      const Color(0xFF064E3B)),
                                if (status != null) _StatusBadge(status),
                              ]),
                              const SizedBox(height: 2),
                              Text(city.description,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: isPas
                                          ? _textSecondary(context)
                                          : _textSecondary(context))),
                              const SizedBox(height: 3),
                              Text(
                                  'Passagem estimada: ${_formatDateHour(city.passTime)}',
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      color: _textSecondary(context))),
                            ])),
                        const SizedBox(width: 12),
                        Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(_fmtTemp(city.temperature),
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: isPas
                                          ? const Color(0xFF9CA3AF)
                                          : dc)),
                              Text(_weatherEmoji(city.condition),
                                  style: const TextStyle(fontSize: 18)),
                              const SizedBox(height: 4),
                              Icon(
                                  _expanded
                                      ? Icons.keyboard_arrow_up
                                      : Icons.keyboard_arrow_down,
                                  size: 18,
                                  color: const Color(0xFF9CA3AF)),
                            ]),
                      ]))),
              if (_expanded)
                Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Container(
                        decoration: BoxDecoration(
                            color: _surfaceAlt(context),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _border(context))),
                        padding: const EdgeInsets.all(12),
                        child: Column(children: [
                          _dr(
                              Icons.schedule,
                              'Tempo desde a saída',
                              city.etaMinutesFromStart == null
                                  ? '--'
                                  : _formatEtaFromMinutes(
                                      city.etaMinutesFromStart)),
                          _dr(Icons.access_time, 'Horário da previsão',
                              _formatDateHour(city.passTime)),
                          const SizedBox(height: 6),
                          _cmp(
                              Icons.thermostat,
                              'Temperatura',
                              city.currentTemperature == null
                                  ? 'Agora indisponível'
                                  : _fmtTemp(city.currentTemperature),
                              _fmtTemp(city.temperature),
                              _cmpTemp(
                                  city.currentTemperature, city.temperature)),
                          _cmp(
                              Icons.grain,
                              'Chance de chuva',
                              city.currentPrecipitationProbability == null
                                  ? 'Agora indisponível'
                                  : '${city.currentPrecipitationProbability}%',
                              city.precipitationProbability == null
                                  ? '--'
                                  : '${city.precipitationProbability}%',
                              _cmpPct(city.currentPrecipitationProbability,
                                  city.precipitationProbability)),
                          _cmp(
                              Icons.air,
                              'Vento',
                              city.currentWindSpeedKmh == null
                                  ? 'Agora indisponível'
                                  : '${city.currentWindSpeedKmh!.toStringAsFixed(1)} km/h',
                              city.windSpeedKmh == null
                                  ? '--'
                                  : '${city.windSpeedKmh!.toStringAsFixed(1)} km/h',
                              _cmpDbl(city.currentWindSpeedKmh,
                                  city.windSpeedKmh, 'km/h')),
                          _cmp(
                              Icons.wb_sunny,
                              'Condição do tempo',
                              city.currentCondition == null
                                  ? 'Agora indisponível'
                                  : '${_weatherEmoji(city.currentCondition!)} ${_weatherLabel(city.currentCondition!)}',
                              '${_weatherEmoji(city.condition)} ${_weatherLabel(city.condition)}',
                              _cmpCond(city.currentCondition, city.condition)),
                          const SizedBox(height: 2),
                          _trafficInfo(city),
                        ]))),
            ])));

    if (isCur) {
      card = AnimatedBuilder(
          animation: _pa,
          builder: (_, child) => Container(
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                        color: const Color(0xFFF59E0B)
                            .withOpacity(0.18 * _pa.value),
                        blurRadius: 24,
                        spreadRadius: 4)
                  ]),
              child: child),
          child: card);
    }
    return card;
  }

  Widget _dr(IconData ic, String lbl, String val, {bool isLast = false}) =>
      Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
          child: Row(children: [
            Icon(ic, size: 15, color: const Color(0xFF64748B)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(lbl,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF64748B)))),
            Text(val,
                style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF1F2937),
                    fontWeight: FontWeight.w600))
          ]));

  Widget _cmp(IconData ic, String title, String now, String forecast,
          String insight, {bool isLast = false}) =>
      Padding(
          padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
          child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                  color: _surface(context),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _border(context))),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(ic, size: 15, color: const Color(0xFF2563EB)),
                      const SizedBox(width: 6),
                      Text(title,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF0F172A)))
                    ]),
                    const SizedBox(height: 6),
                    Text('Agora: $now',
                        style: TextStyle(
                            fontSize: 12, color: _textSecondary(context))),
                    Text('Previsão no ponto: $forecast',
                        style: TextStyle(
                            fontSize: 12, color: _textSecondary(context))),
                    const SizedBox(height: 4),
                    Text(insight,
                        style: TextStyle(
                            fontSize: 11.5,
                            color: _textSecondary(context),
                            fontWeight: FontWeight.w600)),
                  ])));

  String _cmpTemp(int? now, int forecast) {
    if (now == null) return 'Sem dados atuais para comparar.';
    final d = forecast - now;
    if (d == 0) return 'Temperatura prevista igual à de agora.';
    final diff = widget.tempUnit == 'F' ? (d.abs() * 9 / 5).round() : d.abs();
    final unit = widget.tempUnit == 'F' ? '°F' : '°C';
    return d > 0
        ? 'Previsão cerca de $diff$unit mais quente que agora.'
        : 'Previsão cerca de $diff$unit mais fria que agora.';
  }

  String _fmtTemp(int? celsius) {
    if (celsius == null) return '--';
    if (widget.tempUnit == 'F') {
      final f = ((celsius * 9) / 5 + 32).round();
      return '$f°F';
    }
    return '$celsius°C';
  }

  String _cmpPct(int? now, int? fc) {
    if (now == null || fc == null) return 'Comparativo de chuva indisponível.';
    final d = fc - now;
    if (d == 0) return 'Probabilidade de chuva igual ao momento atual.';
    return d > 0
        ? 'Previsão com +${d.abs()} p.p. em relação a agora.'
        : 'Previsão com -${d.abs()} p.p. em relação a agora.';
  }

  String _cmpDbl(double? now, double? fc, String unit) {
    if (now == null || fc == null) return 'Comparativo indisponível.';
    final d = fc - now;
    if (d.abs() < 0.05) return 'Valor previsto praticamente igual ao atual.';
    return d > 0
        ? 'Previsão cerca de ${d.abs().toStringAsFixed(1)} $unit acima de agora.'
        : 'Previsão cerca de ${d.abs().toStringAsFixed(1)} $unit abaixo de agora.';
  }

  String _cmpCond(WeatherCondition? now, WeatherCondition fc) {
    if (now == null) return 'Sem dados atuais para comparar a condição.';
    if (now == fc) return 'Condição prevista semelhante à atual.';
    return 'Mudança esperada: de ${_weatherLabel(now)} para ${_weatherLabel(fc)}.';
  }

  Widget _trafficInfo(RouteCity city) {
    final ff = city.trafficFreeFlowSpeedKmh;
    final cur = city.trafficCurrentSpeedKmh;
    final ratio = city.trafficFlowRatio;
    if (ff == null || cur == null || ratio == null) {
      return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
              color: _surface(context),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _border(context))),
          child: const Row(children: [
            Icon(Icons.traffic, size: 15, color: Color(0xFF64748B)),
            SizedBox(width: 6),
            Text('Trânsito indisponível para esta cidade',
                style: TextStyle(fontSize: 12, color: Color(0xFF475569)))
          ]));
    }

    Color levelColor;
    String levelLabel;
    if (ratio <= 0.40) {
      levelColor = const Color(0xFFDC2626);
      levelLabel = 'Intenso';
    } else if (ratio <= 0.70) {
      levelColor = const Color(0xFFF59E0B);
      levelLabel = 'Moderado';
    } else {
      levelColor = const Color(0xFF059669);
      levelLabel = 'Livre';
    }

    return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: _surface(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _border(context))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.traffic, size: 15, color: Color(0xFF2563EB)),
            const SizedBox(width: 6),
            const Text('Trânsito no ponto',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A))),
            const Spacer(),
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: levelColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(999)),
                child: Text(levelLabel,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: levelColor))),
          ]),
          const SizedBox(height: 6),
          Text(
              'Velocidade atual: ${cur.toStringAsFixed(0)} km/h · livre: ${ff.toStringAsFixed(0)} km/h',
              style: const TextStyle(fontSize: 12, color: Color(0xFF334155))),
        ]));
  }

  Widget _badge(String lbl, Color bg, Color fg) => Container(
      margin: const EdgeInsets.only(left: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(lbl,
          style:
              TextStyle(fontSize: 10, color: fg, fontWeight: FontWeight.w500)));
}

class _CitySelectionChip extends StatelessWidget {
  final RouteCity city;
  final bool selected;
  final ValueChanged<bool> onChanged;
  final String tempUnit;
  const _CitySelectionChip(
      {required this.city,
      required this.selected,
      required this.onChanged,
      required this.tempUnit});
  @override
  Widget build(BuildContext ctx) {
    final isKey = city.isOrigin || city.isDestination;
    final dc = city.isOrigin
        ? const Color(0xFF1D4ED8)
        : city.isDestination
            ? const Color(0xFF065F46)
            : const Color(0xFF3B82F6);
    return GestureDetector(
        onTap: () => onChanged(!selected),
        child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
                color: selected ? dc.withOpacity(0.08) : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: selected ? dc : const Color(0xFFE2E8F0),
                    width: selected ? 1.8 : 1.0),
                boxShadow: selected
                    ? [
                        BoxShadow(
                            color: dc.withOpacity(0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2))
                      ]
                    : [
                        BoxShadow(
                            color: Colors.black.withOpacity(0.04),
                            blurRadius: 4,
                            offset: const Offset(0, 1))
                      ]),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                      color: selected ? dc : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: selected ? dc : const Color(0xFFCBD5E1),
                          width: 1.5)),
                  child: selected
                      ? const Icon(Icons.check, color: Colors.white, size: 13)
                      : null),
              const SizedBox(width: 10),
              Container(
                  width: isKey ? 10 : 8,
                  height: isKey ? 10 : 8,
                  decoration: BoxDecoration(
                      color: selected ? dc : const Color(0xFFCBD5E1),
                      shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      Flexible(
                          child: Text(city.city,
                              style: TextStyle(
                                  fontWeight:
                                      isKey ? FontWeight.w600 : FontWeight.w500,
                                  fontSize: 14,
                                  color:
                                      selected ? dc : const Color(0xFF374151)),
                              overflow: TextOverflow.ellipsis)),
                      if (city.isOrigin)
                        _b('Origem', const Color(0xFFDBEAFE),
                            const Color(0xFF1E40AF)),
                      if (city.isDestination)
                        _b('Destino', const Color(0xFFD1FAE5),
                            const Color(0xFF064E3B)),
                    ]),
                    if (city.temperature != 0) ...[
                      const SizedBox(height: 2),
                      Text(
                          '${_fmtTemp(city.temperature)} · ${city.condition == WeatherCondition.sunny ? '☀️ Ensolarado' : city.condition == WeatherCondition.rainy ? '🌧️ Chuvoso' : '☁️ Nublado'}',
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF6B7280)))
                    ],
                  ])),
            ])));
  }

  Widget _b(String l, Color bg, Color fg) => Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(l,
          style:
              TextStyle(fontSize: 9, color: fg, fontWeight: FontWeight.w600)));

  String _fmtTemp(int celsius) {
    if (tempUnit == 'F') {
      final f = ((celsius * 9) / 5 + 32).round();
      return '$f°F';
    }
    return '$celsius°C';
  }
}

// =============================================================================
// SECTION 14 — PAINEL DE ESTATÍSTICAS (_TripStatsPanel)
// =============================================================================

class _TripStatsPanel extends StatelessWidget {
  final List<TripRecord> records;
  final VoidCallback onClearSavedRoutes;
  final VoidCallback onClearHistory;
  const _TripStatsPanel(
      {required this.records,
      required this.onClearSavedRoutes,
      required this.onClearHistory});

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 10,
                    offset: const Offset(0, 2))
              ]),
          child: const Column(children: [
            Icon(Icons.bar_chart_rounded, size: 40, color: Color(0xFF94A3B8)),
            SizedBox(height: 10),
            Text('Nenhuma viagem concluída ainda',
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1F2937))),
            SizedBox(height: 4),
            Text('Conclua sua primeira viagem para ver as estatísticas aqui.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: OutlinedButton.icon(
                  onPressed: onClearSavedRoutes,
                  icon: const Icon(Icons.star_outline_rounded, size: 16),
                  label: const Text('Excluir rotas salvas'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))))),
          const SizedBox(width: 10),
          Expanded(
              child: OutlinedButton.icon(
                  onPressed: onClearHistory,
                  icon: const Icon(Icons.delete_outline_rounded, size: 16),
                  label: const Text('Excluir histórico'),
                  style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))))),
        ])
      ]);
    }

    // Agrega dados de todas as viagens para o resumo geral
    final totalCities =
        records.fold(<String>{}, (s, r) => s..addAll(r.cityNames)).length;
    final totalKm = records.fold(0.0, (s, r) => s + r.distanceKm);
    final totalRainyMin = records.fold(0, (s, r) => s + r.rainyMinutes);
    final rainyH = totalRainyMin ~/ 60;
    final rainyM = totalRainyMin % 60;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              gradient: const LinearGradient(
                  colors: [Color(0xFF2563EB), Color(0xFF06B6D4)]),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                    color: const Color(0xFF2563EB).withOpacity(0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4))
              ]),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.insights_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text('Minhas estatísticas',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold))
            ]),
            const SizedBox(height: 4),
            Text(
                '${records.length} viagem${records.length > 1 ? "s" : ""} concluída${records.length > 1 ? "s" : ""}',
                style: const TextStyle(color: Color(0xFFBAE6FD), fontSize: 12)),
            const SizedBox(height: 16),
            Row(children: [
              _hs(Icons.location_city_rounded, '$totalCities',
                  'cidades visitadas'),
              const SizedBox(width: 10),
              _hs(
                  Icons.straighten_rounded,
                  totalKm < 1000
                      ? '${totalKm.toStringAsFixed(0)} km'
                      : '${(totalKm / 1000).toStringAsFixed(1)} mil km',
                  'percorridos'),
              const SizedBox(width: 10),
              _hs(
                  Icons.water_drop_rounded,
                  rainyH > 0 ? '${rainyH}h ${rainyM}min' : '${rainyM}min',
                  'sob chuva'),
            ]),
          ])),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
            child: OutlinedButton.icon(
                onPressed: onClearSavedRoutes,
                icon: const Icon(Icons.star_outline_rounded, size: 16),
                label: const Text('Excluir rotas salvas'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))))),
        const SizedBox(width: 10),
        Expanded(
            child: OutlinedButton.icon(
                onPressed: onClearHistory,
                icon: const Icon(Icons.delete_outline_rounded, size: 16),
                label: const Text('Excluir histórico'),
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))))),
      ]),
      const SizedBox(height: 16),
      const Text('Histórico recente',
          style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1F2937))),
      const SizedBox(height: 10),
      Container(
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 10,
                    offset: const Offset(0, 2))
              ]),
          child: Column(children: [
            for (int i = 0; i < records.take(8).length; i++) ...[
              _ht(records[i]),
              if (i < records.take(8).length - 1)
                const Divider(
                    height: 1,
                    color: Color(0xFFF1F5F9),
                    indent: 16,
                    endIndent: 16),
            ],
          ])),
    ]);
  }

  Widget _hs(IconData ic, String val, String lbl) => Expanded(
      child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.18),
              borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Icon(ic, color: Colors.white70, size: 20),
            const SizedBox(height: 6),
            Text(val,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(lbl,
                style: const TextStyle(color: Colors.white60, fontSize: 10),
                textAlign: TextAlign.center)
          ])));

  Widget _ht(TripRecord r) {
    final h = r.durationMinutes ~/ 60;
    final m = r.durationMinutes % 60;
    final dur = h > 0 ? '${h}h ${m}min' : '${m}min';
    final d = r.startedAt;
    final ds =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(children: [
          Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.directions_car_rounded,
                  color: Color(0xFF2563EB), size: 20)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text('${r.origin} → ${r.destination}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F172A)),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                    '$ds · ${r.cityNames.length} cidades · ${r.distanceKm.toStringAsFixed(0)} km',
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF64748B))),
              ])),
          Text(dur,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF2563EB))),
        ]));
  }
}

// =============================================================================
// SECTION 15 — TELA PRINCIPAL (RouteScreen + _RouteScreenState)
// =============================================================================

class RouteScreen extends StatefulWidget {
  final String initialFrom;
  final String initialTo;
  const RouteScreen({super.key, this.initialFrom = '', this.initialTo = ''});
  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  // ── Rota atual ────────────────────────────────────────────────────────────
  late String _origin;
  late String _destination;
  List<RouteCity> _allCities = [];
  List<LatLng> _routePolyline = [];
  Set<String> _selectedCityNames = {};
  double? _routeDurationSeconds;

  // ── UI de rota ────────────────────────────────────────────────────────────
  bool _selectAll = true;
  bool _showCitySelector = true;
  bool _isEditingRoute = false;
  bool _isLoadingRoute = false;
  String _loadingMessage = 'Buscando cidades e dados climáticos...';
  int _tripsTabIndex = 0;

  // ── GPS tracking ──────────────────────────────────────────────────────────
  bool _tripStarted = false;
  bool _tripFinished = false;
  Position? _currentPosition;
  StreamSubscription<Position>? _positionSub;
  Map<String, CityStatus> _cityStatuses = {};
  int _currentCityIndex = 0;
  DateTime? _tripStartedAt;

  // ── Favoritos e histórico ─────────────────────────────────────────────────
  List<FavoriteRoute> _favoriteRoutes = [];
  List<TripRecord> _tripRecords = [];
  bool _favoritesLoading = true;
  String _tempUnit = 'C';
  bool _trafficLoading = false;

  // ── Autocomplete ──────────────────────────────────────────────────────────
  late TextEditingController _originCtrl, _destinationCtrl;
  List<RouteLocationSuggestion> _originSuggestions = [],
      _destinationSuggestions = [];
  bool _originSearchLoading = false, _destinationSearchLoading = false;
  bool _showOriginSuggestions = false, _showDestinationSuggestions = false;
  Timer? _originDebounce, _destinationDebounce;

  @override
  void initState() {
    super.initState();
    _origin = widget.initialFrom;
    _destination = widget.initialTo;
    _originCtrl = TextEditingController(text: _origin);
    _destinationCtrl = TextEditingController(text: _destination);
    _loadFavorites();
    _loadRecords();
    _loadTempUnit();
    if (_origin.isNotEmpty && _destination.isNotEmpty) _initializeRoute();
  }

  @override
  void dispose() {
    _originDebounce?.cancel();
    _destinationDebounce?.cancel();
    _originCtrl.dispose();
    _destinationCtrl.dispose();
    _positionSub?.cancel();
    super.dispose();
  }

  // ── Persistência ──────────────────────────────────────────────────────────

  Future<void> _loadFavorites() async {
    final f = await _loadFavoriteRoutes();
    if (!mounted) return;
    setState(() {
      _favoriteRoutes = f;
      _favoritesLoading = false;
    });
  }

  Future<void> _loadRecords() async {
    final r = await _loadTripRecords();
    if (!mounted) return;
    setState(() => _tripRecords = r);
  }

  Future<void> _clearSavedRoutes() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
                title: const Text('Excluir rotas salvas'),
                content: const Text(
                    'Deseja remover todas as rotas salvas em Minhas viagens?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar')),
                  ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD97706)),
                      child: const Text('Excluir',
                          style: TextStyle(color: Colors.white))),
                ]));
    if (ok != true) return;
    await _clearFavoriteRoutes();
    if (!mounted) return;
    setState(() => _favoriteRoutes = []);
    _showSnack('Rotas salvas removidas.');
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18)),
                title: const Text('Excluir histórico'),
                content: const Text(
                    'Deseja apagar o histórico e os dados das estatísticas?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar')),
                  ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFDC2626)),
                      child: const Text('Excluir',
                          style: TextStyle(color: Colors.white))),
                ]));
    if (ok != true) return;
    await _clearTripRecords();
    if (!mounted) return;
    setState(() => _tripRecords = []);
    _showSnack('Histórico e estatísticas removidos.');
  }

  Future<void> _loadTempUnit() async {
    final prefs = await SharedPreferences.getInstance();
    final unit = (prefs.getString(_unitPrefsKey) ?? 'C').toUpperCase();
    if (!mounted) return;
    setState(() => _tempUnit = unit == 'F' ? 'F' : 'C');
  }

  // ── Favoritar rota ────────────────────────────────────────────────────────

  bool get _isCurrentRouteFavorite {
    if (_origin.trim().isEmpty || _destination.trim().isEmpty) return false;
    return _favoriteRoutes
        .any((r) => r.key == _routePairKey(_origin, _destination));
  }

  Future<void> _toggleCurrentRouteFavorite() async {
    if (_origin.trim().isEmpty || _destination.trim().isEmpty) return;
    final key = _routePairKey(_origin, _destination);
    final updated = List<FavoriteRoute>.from(_favoriteRoutes);
    final idx = updated.indexWhere((r) => r.key == key);
    final adding = idx < 0;
    if (adding) {
      updated.insert(
          0,
          FavoriteRoute(
              origin: _origin.trim(),
              destination: _destination.trim(),
              savedAt: DateTime.now()));
    } else {
      updated.removeAt(idx);
    }
    await _saveFavoriteRoutes(updated);
    if (!mounted) return;
    setState(() => _favoriteRoutes = updated);
    _showSnack(adding
        ? 'Rota salva em Minhas Viagens.'
        : 'Rota removida de Minhas Viagens.');
  }

  Future<void> _openFavoriteRoute(FavoriteRoute route) async {
    if (_isLoadingRoute) return;
    setState(() => _tripsTabIndex = 0);
    await _setRoute(route.origin, route.destination);
  }

  Future<void> _removeFavoriteRoute(FavoriteRoute route) async {
    final updated = _favoriteRoutes.where((r) => r.key != route.key).toList();
    await _saveFavoriteRoutes(updated);
    if (!mounted) return;
    setState(() => _favoriteRoutes = updated);
    _showSnack('Rota removida de Minhas Viagens.');
  }

  Future<void> _invertFavoriteRoute(FavoriteRoute route) async {
    if (_isLoadingRoute) return;
    setState(() => _tripsTabIndex = 0);
    await _setRoute(route.destination, route.origin);
  }

  // ── Ciclo de vida da rota ─────────────────────────────────────────────────

  Future<void> _initializeRoute() async {
    final dep = DateTime.now();
    setState(() {
      _isLoadingRoute = true;
      _loadingMessage = 'Calculando pontos da rota...';
      _tripStarted = false;
      _tripFinished = false;
      _cityStatuses = {};
      _currentCityIndex = 0;
      _positionSub?.cancel();
      _positionSub = null;
      _trafficLoading = false;
    });
    final cities = await _getRouteCities(_origin, _destination);
    final routeData = await _resolveRouteDataByNames(_origin, _destination);
    if (!mounted) return;
    setState(() => _loadingMessage = 'Calculando previsão por horário...');
    final enriched = await _enrichCitiesWithEtaAndHourlyWeather(cities,
        departureTime: dep, routeDurationSeconds: routeData.durationSeconds);
    if (!mounted) return;
    setState(() {
      _allCities = enriched;
      _routePolyline = routeData.points.isNotEmpty
          ? routeData.points
          : enriched.map((c) => LatLng(c.lat, c.lng)).toList();
      _routeDurationSeconds = routeData.durationSeconds;
      _selectedCityNames = enriched.map((c) => c.city).toSet();
      _selectAll = true;
      _showCitySelector = true;
      _isLoadingRoute = false;
    });
    _loadTrafficOverlay();
  }

  Future<void> _setRoute(String o, String d) async {
    if (o.isEmpty || d.isEmpty) return;
    setState(() {
      _origin = o;
      _destination = d;
      _originCtrl.text = o;
      _destinationCtrl.text = d;
      _showOriginSuggestions = false;
      _showDestinationSuggestions = false;
      _isEditingRoute = false;
      _allCities = [];
      _routePolyline = [];
      _selectedCityNames = {};
      _routeDurationSeconds = null;
      _showCitySelector = true;
      _trafficLoading = false;
    });
    await _initializeRoute();
  }

  Future<void> _loadTrafficOverlay() async {
    final poly = _routePolyline;
    if (poly.length < 2) {
      if (!mounted) return;
      setState(() {
        _trafficLoading = false;
      });
      return;
    }

    setState(() => _trafficLoading = true);
    final sem = _Semaphore(4);
    final updated = await Future.wait(_allCities.map((city) async {
      await sem.acquire();
      try {
        final flow = await _fetchTrafficFlowAtPoint(city.lat, city.lng);
        if (flow == null) {
          return city.copyWith(
            trafficFreeFlowSpeedKmh: null,
            trafficCurrentSpeedKmh: null,
            trafficFlowRatio: null,
          );
        }
        final freeFlow = flow.$1;
        final current = flow.$2;
        final ratio =
            freeFlow <= 0 ? 1.0 : (current / freeFlow).clamp(0.0, 1.0);
        return city.copyWith(
          trafficFreeFlowSpeedKmh: freeFlow,
          trafficCurrentSpeedKmh: current,
          trafficFlowRatio: ratio,
        );
      } finally {
        sem.release();
      }
    }));

    if (!mounted) return;
    setState(() {
      _allCities = updated;
      _trafficLoading = false;
    });
  }

  /// Retorna (freeFlowSpeed, currentSpeed) em km/h para um ponto da rota.
  Future<(double, double)?> _fetchTrafficFlowAtPoint(
      double lat, double lng) async {
    try {
      final uri = _backendUri(
        '/api/traffic',
        {
          'lat': lat.toString(),
          'lon': lng.toString(),
        },
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>?;
      final fs = data?['flowSegmentData'] as Map<String, dynamic>?;
      if (fs == null) return null;
      final ff = (fs['freeFlowSpeed'] as num?)?.toDouble();
      final cur = (fs['currentSpeed'] as num?)?.toDouble();
      if (ff == null || cur == null) return null;
      return (ff, cur);
    } catch (_) {
      return null;
    }
  }

  /// Resolve a polilinha para exibição no mapa (LatLng em vez de tuplas).
  Future<({List<LatLng> points, double? durationSeconds})>
      _resolveRouteDataByNames(String o, String d) async {
    final oL = await _searchLocation(o);
    final dL = await _searchLocation(d);
    final oLa = (oL?['latitude'] as num?)?.toDouble();
    final oLo = (oL?['longitude'] as num?)?.toDouble();
    final dLa = (dL?['latitude'] as num?)?.toDouble();
    final dLo = (dL?['longitude'] as num?)?.toDouble();
    if (oLa == null || oLo == null || dLa == null || dLo == null)
      return (points: <LatLng>[], durationSeconds: null);
    var rd = await _fetchRoadRouteData(oLa, oLo, dLa, dLo);
    if (rd.points.length < 2) {
      final rev = await _fetchRoadRouteData(dLa, dLo, oLa, oLo);
      if (rev.points.length >= 2)
        rd = RoadRouteData(
            points: rev.points.reversed.toList(),
            durationSeconds: rev.durationSeconds);
    }
    if (rd.points.length < 2)
      return (points: <LatLng>[], durationSeconds: rd.durationSeconds);
    return (
      points: rd.points.map((p) => LatLng(p.$1, p.$2)).toList(),
      durationSeconds: rd.durationSeconds
    );
  }

  // ── GPS tracking ──────────────────────────────────────────────────────────

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _showSnack('Ative o GPS para iniciar a viagem.');
      return false;
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied)
      p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied ||
        p == LocationPermission.deniedForever) {
      _showSnack('Permissão de localização necessária.');
      return false;
    }
    return true;
  }

  Future<void> _startTrip() async {
    if (_allCities.isEmpty || !await _ensureLocationPermission()) return;
    final statuses = {for (final c in _allCities) c.city: CityStatus.upcoming};
    setState(() {
      _tripStarted = true;
      _tripFinished = false;
      _cityStatuses = statuses;
      _currentCityIndex = 0;
      _showCitySelector = false;
    });
    _tripStartedAt = DateTime.now();
    try {
      final pos = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium,
          timeLimit: const Duration(seconds: 8));
      _onPositionUpdate(pos);
    } catch (_) {}
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high, distanceFilter: 200),
    ).listen(_onPositionUpdate);
  }

  /// Atualiza o status das cidades com base na posição atual do GPS.
  ///
  /// Lógica:
  ///  1. Para cada cidade (na ordem da rota) que ainda não foi passed:
  ///     - Se dist ≤ _cityArrivalRadiusKm → marca como current e todas as
  ///       anteriores como passed. Se for o destino, finaliza a viagem.
  ///     - Se estamos entre cidade i e i+1 e i+1 está mais próxima →
  ///       marca i como passed (o usuário ultrapassou).
  void _onPositionUpdate(Position pos) {
    if (!mounted || !_tripStarted || _tripFinished) return;
    setState(() => _currentPosition = pos);
    final lat = pos.latitude, lng = pos.longitude;
    final ns = Map<String, CityStatus>.from(_cityStatuses);
    int ni = _currentCityIndex;

    for (int i = 0; i < _allCities.length; i++) {
      final city = _allCities[i];
      if (ns[city.city] == CityStatus.passed) continue;
      final dist = _distanceKm(lat, lng, city.lat, city.lng);

      if (dist <= _cityArrivalRadiusKm) {
        for (int j = 0; j < i; j++) ns[_allCities[j].city] = CityStatus.passed;
        ns[city.city] = CityStatus.current;
        ni = i;
        if (city.isDestination) {
          _finishTripWithRecord(auto: true);
          return;
        }
      } else if (i == _currentCityIndex && i < _allCities.length - 1) {
        final next = _allCities[i + 1];
        if (_distanceKm(lat, lng, next.lat, next.lng) < dist &&
            dist > _cityArrivalRadiusKm * 1.5) {
          ns[city.city] = CityStatus.passed;
          if (ns[next.city] != CityStatus.current)
            ns[next.city] = CityStatus.upcoming;
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _cityStatuses = ns;
      _currentCityIndex = ni;
    });
  }

  /// Encerra a viagem, calcula as métricas e persiste o [TripRecord].
  void _finishTripWithRecord({bool auto = false}) async {
    _positionSub?.cancel();
    _positionSub = null;
    final fs = {for (final c in _allCities) c.city: CityStatus.passed};

    // Distância real pela polilinha OSRM; fallback Haversine origem→destino
    double distKm = 0;
    if (_routePolyline.length > 1) {
      for (int i = 1; i < _routePolyline.length; i++) {
        distKm += _distanceKm(
            _routePolyline[i - 1].latitude,
            _routePolyline[i - 1].longitude,
            _routePolyline[i].latitude,
            _routePolyline[i].longitude);
      }
    } else if (_allCities.length >= 2) {
      distKm = _distanceKm(_allCities.first.lat, _allCities.first.lng,
          _allCities.last.lat, _allCities.last.lng);
    }

    // Estimativa de tempo sob chuva: qtd_cidades_chuvosas × tempo_médio_por_cidade
    final rainyCities =
        _allCities.where((c) => c.condition == WeatherCondition.rainy).length;
    final avgMin = (_allCities.length > 1 && _routeDurationSeconds != null)
        ? (_routeDurationSeconds! / 60 / (_allCities.length - 1)).round()
        : 20;

    final record = TripRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      origin: _origin,
      destination: _destination,
      startedAt: _tripStartedAt ?? DateTime.now(),
      finishedAt: DateTime.now(),
      cityNames: _allCities.map((c) => c.city).toList(),
      distanceKm: distKm,
      rainyMinutes: rainyCities * avgMin,
    );

    await _saveTripRecord(record);
    setState(() {
      _tripFinished = true;
      _tripStarted = false;
      _cityStatuses = fs;
      _tripRecords = [record, ..._tripRecords];
    });
    _showSnack(auto
        ? '🏁 Você chegou ao destino! Viagem concluída.'
        : '✅ Viagem finalizada com sucesso!');
  }

  void _resetRouteScreenForNewTrip() {
    _positionSub?.cancel();
    _positionSub = null;
    setState(() {
      _tripFinished = false;
      _tripStarted = false;
      _currentPosition = null;
      _cityStatuses = {};
      _currentCityIndex = 0;
      _origin = '';
      _destination = '';
      _originCtrl.clear();
      _destinationCtrl.clear();
      _allCities = [];
      _routePolyline = [];
      _selectedCityNames = {};
      _routeDurationSeconds = null;
      _showCitySelector = true;
      _selectAll = true;
      _isEditingRoute = false;
      _isLoadingRoute = false;
      _loadingMessage = 'Buscando cidades e dados climáticos...';
      _originSuggestions = [];
      _destinationSuggestions = [];
      _showOriginSuggestions = false;
      _showDestinationSuggestions = false;
      _originSearchLoading = false;
      _destinationSearchLoading = false;
      _tripsTabIndex = 0;
      _trafficLoading = false;
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Autocomplete ──────────────────────────────────────────────────────────

  void _onOriginChanged(String q) {
    _originDebounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _originSuggestions = [];
        _showOriginSuggestions = false;
      });
      return;
    }
    _originDebounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _originSearchLoading = true);
      final r = await _searchLocations(q.trim());
      if (!mounted) return;
      setState(() {
        _originSuggestions = r;
        _showOriginSuggestions = true;
        _originSearchLoading = false;
      });
    });
  }

  void _onDestinationChanged(String q) {
    _destinationDebounce?.cancel();
    if (q.trim().length < 2) {
      setState(() {
        _destinationSuggestions = [];
        _showDestinationSuggestions = false;
      });
      return;
    }
    _destinationDebounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() => _destinationSearchLoading = true);
      final r = await _searchLocations(q.trim());
      if (!mounted) return;
      setState(() {
        _destinationSuggestions = r;
        _showDestinationSuggestions = true;
        _destinationSearchLoading = false;
      });
    });
  }

  void _selectOriginSuggestion(RouteLocationSuggestion s) => setState(() {
        _originCtrl.text = s.name;
        _originSuggestions = [];
        _showOriginSuggestions = false;
      });
  void _selectDestinationSuggestion(RouteLocationSuggestion s) => setState(() {
        _destinationCtrl.text = s.name;
        _destinationSuggestions = [];
        _showDestinationSuggestions = false;
      });
  void _handleUpdateRoute() {
    final o = _originCtrl.text.trim(), d = _destinationCtrl.text.trim();
    if (o.isNotEmpty && d.isNotEmpty) _setRoute(o, d);
  }

  // ── Seleção de cidades ────────────────────────────────────────────────────

  void _toggleCity(String name, bool sel) {
    setState(() {
      if (sel)
        _selectedCityNames.add(name);
      else
        _selectedCityNames.remove(name);
      _selectAll = _selectedCityNames.length == _allCities.length;
    });
  }

  void _toggleSelectAll(bool? v) {
    setState(() {
      _selectAll = v ?? true;
      if (_selectAll)
        _selectedCityNames = _allCities.map((c) => c.city).toSet();
      else
        _selectedCityNames.clear();
    });
  }

  List<RouteCity> get _visibleCities => _selectAll
      ? _allCities
      : _allCities.where((c) => _selectedCityNames.contains(c.city)).toList();

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _pageBg(context),
      body: Column(children: [
        _buildHeader(),
        Expanded(
            child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
                child: _buildBody())),
      ]),
      bottomNavigationBar: const BottomNavigation(),
    );
  }

  Widget _buildHeader() => Container(
      decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: _isDarkMode(context)
                  ? const [Color(0xFF0F172A), Color(0xFF1E293B)]
                  : const [Color(0xFF2563EB), Color(0xFF06B6D4)]),
          boxShadow: [
            BoxShadow(
                color: Colors.black26, blurRadius: 8, offset: Offset(0, 2))
          ]),
      child: SafeArea(
          bottom: false,
          child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Row(children: [
                IconButton(
                    onPressed: () =>
                        context.canPop() ? context.pop() : context.go('/home'),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    style: IconButton.styleFrom(
                        backgroundColor: Colors.white24,
                        shape: const CircleBorder())),
                const SizedBox(width: 8),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Text('Viagens',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                      Text(
                          _tripStarted
                              ? '🟢 Viagem em andamento'
                              : _tripFinished
                                  ? '🏁 Viagem concluída'
                                  : 'Planeje sua próxima aventura',
                          style: const TextStyle(
                              color: Color(0xFFBFDBFE), fontSize: 13)),
                    ])),
                if (_tripStarted && _currentPosition != null)
                  Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20)),
                      child:
                          Row(mainAxisSize: MainAxisSize.min, children: const [
                        Icon(Icons.gps_fixed, color: Colors.white, size: 14),
                        SizedBox(width: 4),
                        Text('GPS ativo',
                            style: TextStyle(color: Colors.white, fontSize: 11))
                      ])),
              ]))));

  Widget _buildBody() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildTripsTabs(),
        const SizedBox(height: 12),
        if (_tripsTabIndex == 1)
          _buildMyTripsTab()
        else ...[
          _buildRouteCard(),
          const SizedBox(height: 16),
          if (_isLoadingRoute)
            _RouteLoadingCard(message: _loadingMessage)
          else if (_allCities.isNotEmpty) ...[
            if (!_tripStarted && !_tripFinished) ...[
              Row(children: [
                _sectionTitle('Cidades na Rota'),
                const Spacer(),
                TextButton.icon(
                    onPressed: () =>
                        setState(() => _showCitySelector = !_showCitySelector),
                    icon: Icon(
                        _showCitySelector
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18),
                    label: Text(_showCitySelector ? 'Ocultar' : 'Mostrar'))
              ]),
              const SizedBox(height: 4),
              Text(
                  '${_allCities.length} cidades encontradas · selecione as que deseja visualizar',
                  style:
                      const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
              if (_showCitySelector) ...[
                const SizedBox(height: 10),
                _buildCitySelector()
              ],
              const SizedBox(height: 16),
            ],
            if (_tripStarted || _tripFinished) ...[
              _buildTripProgressBar(),
              const SizedBox(height: 16)
            ],
            _sectionTitle('Visualização da Rota'),
            const SizedBox(height: 10),
            _buildMapCard(),
            const SizedBox(height: 16),
            if (_visibleCities.isNotEmpty) ...[
              _sectionTitle('Clima ao longo da rota'),
              const SizedBox(height: 10),
              _buildCityCards(),
              const SizedBox(height: 16)
            ],
            _buildTripActionButton(),
          ] else if (_origin.isEmpty || _destination.isEmpty)
            _buildEmptyState(),
        ],
      ]);

  Widget _buildTripsTabs() => Container(
      decoration: BoxDecoration(
          color: _surface(context),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ]),
      padding: const EdgeInsets.all(4),
      child: Row(children: [
        Expanded(
            child: _tabBtn('Planejar rota', _tripsTabIndex == 0,
                () => setState(() => _tripsTabIndex = 0))),
        Expanded(
            child: _tabBtn('Minhas viagens', _tripsTabIndex == 1,
                () => setState(() => _tripsTabIndex = 1))),
      ]));

  Widget _tabBtn(String lbl, bool sel, VoidCallback onTap) {
    final color = sel
        ? Colors.white
        : (_isDarkMode(context)
            ? const Color(0xFFCBD5E1)
            : const Color(0xFF334155));

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: sel ? const Color(0xFF2563EB) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            lbl,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMyTripsTab() {
    if (_favoritesLoading)
      return Container(
          padding: const EdgeInsets.symmetric(vertical: 28),
          alignment: Alignment.center,
          child: const CircularProgressIndicator(color: Color(0xFF2563EB)));

    final favWidget = _favoriteRoutes.isEmpty
        ? Container(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
            decoration: BoxDecoration(
                color: _surface(context),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.06),
                      blurRadius: 10,
                      offset: const Offset(0, 2))
                ]),
            child: const Column(children: [
              Icon(Icons.star_border_rounded,
                  size: 44, color: Color(0xFF94A3B8)),
              SizedBox(height: 12),
              Text('Nenhuma viagem favorita',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1F2937))),
              SizedBox(height: 6),
              Text(
                  'Marque uma rota com estrela em Planejar rota para ela aparecer aqui.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Color(0xFF64748B)))
            ]))
        : Container(
            decoration: BoxDecoration(
                color: _surface(context),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.07),
                      blurRadius: 10,
                      offset: const Offset(0, 2))
                ]),
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              for (int i = 0; i < _favoriteRoutes.length; i++) ...[
                _favTile(_favoriteRoutes[i]),
                if (i < _favoriteRoutes.length - 1)
                  const Divider(height: 12, color: Color(0xFFF1F5F9)),
              ]
            ]));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _TripStatsPanel(
          records: _tripRecords,
          onClearSavedRoutes: _clearSavedRoutes,
          onClearHistory: _clearHistory),
      const SizedBox(height: 16),
      favWidget,
    ]);
  }

  Widget _favTile(FavoriteRoute route) => InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openFavoriteRoute(route),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Row(children: [
            Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.route, color: Color(0xFF2563EB))),
            const SizedBox(width: 10),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text('${route.origin} → ${route.destination}',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _textPrimary(context))),
                  const SizedBox(height: 2),
                  Text('Salva em ${_formatDateHour(route.savedAt)}',
                      style: TextStyle(
                          fontSize: 12, color: _textSecondary(context))),
                ])),
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                  tooltip: 'Inverter origem/destino',
                  onPressed: () => _invertFavoriteRoute(route),
                  icon: const Icon(Icons.swap_horiz_rounded,
                      color: Color(0xFF0EA5E9))),
              IconButton(
                  tooltip: 'Remover favorito',
                  onPressed: () => _removeFavoriteRoute(route),
                  icon: const Icon(Icons.delete_outline,
                      color: Color(0xFFEF4444))),
            ]),
          ])));

  Widget _buildTripProgressBar() {
    final total = _allCities.length;
    final passed =
        _cityStatuses.values.where((s) => s == CityStatus.passed).length;
    final cur =
        _cityStatuses.values.where((s) => s == CityStatus.current).length;
    final prog = total == 0 ? 0.0 : (passed + cur * 0.5) / total;
    return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: _surface(context),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.07),
                  blurRadius: 8,
                  offset: const Offset(0, 2))
            ]),
        child: Column(children: [
          Row(children: [
            const Icon(Icons.directions_car,
                size: 18, color: Color(0xFF2563EB)),
            const SizedBox(width: 8),
            Expanded(
                child: Text(
                    _tripFinished
                        ? 'Viagem concluída! 🎉'
                        : 'Progresso da viagem: $passed/$total cidades',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1F2937)))),
            Text('${(prog * 100).toInt()}%',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2563EB)))
          ]),
          const SizedBox(height: 10),
          ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                  value: prog,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFE2E8F0),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF2563EB)))),
          const SizedBox(height: 8),
          Row(children: [
            _pl(const Color(0xFF6B7280), 'Passada', passed),
            const SizedBox(width: 16),
            _pl(const Color(0xFFF59E0B), 'Atual', cur),
            const SizedBox(width: 16),
            _pl(const Color(0xFF3B82F6), 'À frente', total - passed - cur)
          ]),
        ]));
  }

  Widget _pl(Color c, String l, int n) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text('$l: $n',
            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)))
      ]);

  Widget _buildTripActionButton() {
    if (_tripFinished)
      return _gradBtn(
          onTap: _resetRouteScreenForNewTrip,
          colors: [const Color(0xFF059669), const Color(0xFF10B981)],
          h: 52,
          child:
              Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
            Icon(Icons.refresh, color: Colors.white),
            SizedBox(width: 8),
            Text('Nova Viagem',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 16))
          ]));
    if (_tripStarted)
      return Container(
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 12)
              ]),
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Row(children: [
              Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                      color: const Color(0xFF22C55E),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: const Color(0xFF22C55E).withOpacity(0.5),
                            blurRadius: 6)
                      ])),
              const SizedBox(width: 8),
              const Text('Viagem em andamento — GPS ativo',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1F2937)))
            ]),
            const SizedBox(height: 4),
            const Text(
                'Os cards serão atualizados automaticamente conforme você avança.',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            const SizedBox(height: 14),
            GestureDetector(
                onTap: _confirmFinishTrip,
                child: Container(
                    height: 50,
                    decoration: BoxDecoration(
                        color: const Color(0xFFFEF2F2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFEF4444))),
                    child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.flag, color: Color(0xFFEF4444)),
                          SizedBox(width: 8),
                          Text('Finalizar Viagem',
                              style: TextStyle(
                                  color: Color(0xFFEF4444),
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15))
                        ]))),
          ]));
    return _gradBtn(
        onTap: _startTrip,
        colors: _isDarkMode(context)
            ? [const Color(0xFF1D4ED8), const Color(0xFF0EA5E9)]
            : [const Color(0xFF2563EB), const Color(0xFF06B6D4)],
        h: 56,
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
          Icon(Icons.navigation, color: Colors.white, size: 22),
          SizedBox(width: 10),
          Text('Iniciar Viagem',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 17))
        ]));
  }

  Future<void> _confirmFinishTrip() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                title: const Text('Finalizar Viagem'),
                content: const Text(
                    'Tem certeza que deseja encerrar a viagem atual?'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar')),
                  ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFEF4444),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                      child: const Text('Finalizar',
                          style: TextStyle(color: Colors.white)))
                ]));
    if (ok == true) _finishTripWithRecord();
  }

  Widget _buildEmptyState() => Container(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: BoxDecoration(
          color: _surface(context), borderRadius: BorderRadius.circular(20)),
      child: const Column(children: [
        Icon(Icons.route, size: 56, color: Color(0xFFBFDBFE)),
        SizedBox(height: 16),
        Text('Defina sua rota',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1F2937))),
        SizedBox(height: 8),
        Text(
            'Informe a origem e o destino para visualizar o clima ao longo da sua viagem',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)))
      ]));

  Widget _buildRouteCard() => Container(
      decoration: BoxDecoration(
          color: _surface(context),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 12,
                offset: const Offset(0, 3))
          ]),
      padding: const EdgeInsets.all(20),
      child: _isEditingRoute || _origin.isEmpty
          ? _buildEditRouteForm()
          : _buildRouteDisplay());

  Widget _buildRouteDisplay() {
    final dst = _allCities.isNotEmpty ? _allCities.last : null;
    return Column(children: [
      _rRow(Icons.trip_origin, const Color(0xFF2563EB), 'Origem', _origin),
      Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
          child: Row(children: [
            const SizedBox(width: 20),
            Expanded(
                child: Container(height: 1, color: const Color(0xFFE2E8F0))),
            const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.arrow_downward,
                    size: 16, color: Color(0xFF94A3B8))),
            Expanded(
                child: Container(height: 1, color: const Color(0xFFE2E8F0)))
          ])),
      _rRow(
          Icons.location_on, const Color(0xFF06B6D4), 'Destino', _destination),
      if (_routeDurationSeconds != null || dst?.passTime != null)
        Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFBFDBFE))),
            child: Column(children: [
              if (_routeDurationSeconds != null)
                Row(children: [
                  const Icon(Icons.route, size: 16, color: Color(0xFF1D4ED8)),
                  const SizedBox(width: 6),
                  Text(
                      'Duração estimada: ${_formatDuration(_routeDurationSeconds!)}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1E3A8A),
                          fontWeight: FontWeight.w600))
                ]),
              if (dst?.passTime != null) ...[
                if (_routeDurationSeconds != null) const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.flag, size: 16, color: Color(0xFF065F46)),
                  const SizedBox(width: 6),
                  Text('Chegada prevista: ${_formatDateHour(dst!.passTime)}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF065F46),
                          fontWeight: FontWeight.w600))
                ])
              ],
            ])),
      const SizedBox(height: 16),
      if (!_tripStarted)
        Column(children: [
          OutlinedButton.icon(
              onPressed: () => setState(() => _isEditingRoute = true),
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('Editar Rota'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)))),
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: _toggleCurrentRouteFavorite,
              icon: Icon(
                  _isCurrentRouteFavorite
                      ? Icons.star
                      : Icons.star_border_rounded,
                  size: 16,
                  color: _isCurrentRouteFavorite
                      ? const Color(0xFFF59E0B)
                      : const Color(0xFF475569)),
              label: Text(_isCurrentRouteFavorite
                  ? 'Remover de Minhas Viagens'
                  : 'Salvar em Minhas Viagens'),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)))),
        ]),
    ]);
  }

  Widget _rRow(IconData ic, Color c, String l, String v) => Row(children: [
        Icon(ic, color: c, size: 20),
        const SizedBox(width: 8),
        Text(l,
            style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280),
                fontSize: 13)),
        const Spacer(),
        Text(v.isEmpty ? 'Não definido' : v,
            style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
                fontSize: 15))
      ]);

  Widget _buildEditRouteForm() =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _acField(
            _originCtrl,
            'Origem',
            'Digite a origem',
            const Color(0xFF3B82F6),
            _originSearchLoading,
            _originSuggestions,
            _showOriginSuggestions,
            _onOriginChanged,
            _selectOriginSuggestion),
        const SizedBox(height: 16),
        _acField(
            _destinationCtrl,
            'Destino',
            'Digite o destino',
            const Color(0xFF06B6D4),
            _destinationSearchLoading,
            _destinationSuggestions,
            _showDestinationSuggestions,
            _onDestinationChanged,
            _selectDestinationSuggestion),
        const SizedBox(height: 16),
        Row(children: [
          if (_origin.isNotEmpty) ...[
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: () {
                      _originCtrl.text = _origin;
                      _destinationCtrl.text = _destination;
                      setState(() => _isEditingRoute = false);
                    },
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Cancelar'),
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12))))),
            const SizedBox(width: 8)
          ],
          Expanded(
              child: _gradBtn(
                  onTap: _handleUpdateRoute,
                  colors: [const Color(0xFF2563EB), const Color(0xFF06B6D4)],
                  h: 48,
                  child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.search, color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text('Buscar Rota',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600))
                      ]))),
        ]),
      ]);

  Widget _acField(
          TextEditingController ctrl,
          String label,
          String hint,
          Color icColor,
          bool loading,
          List<RouteLocationSuggestion> sug,
          bool showSug,
          ValueChanged<String> onChanged,
          ValueChanged<RouteLocationSuggestion> onSel) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF374151))),
        const SizedBox(height: 6),
        TextField(
            controller: ctrl,
            textInputAction: TextInputAction.next,
            onChanged: onChanged,
            decoration: InputDecoration(
                hintText: hint,
                prefixIcon: Icon(Icons.location_on, color: icColor),
                suffixIcon: loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Color(0xFF2563EB))))
                    : ctrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              setState(() {
                                ctrl.clear();
                                if (label == 'Origem') {
                                  _originSuggestions = [];
                                  _showOriginSuggestions = false;
                                } else {
                                  _destinationSuggestions = [];
                                  _showDestinationSuggestions = false;
                                }
                              });
                            })
                        : null,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 16))),
        if (showSug) ...[const SizedBox(height: 6), _sugList(sug, onSel)],
      ]);

  Widget _sugList(List<RouteLocationSuggestion> sug,
      ValueChanged<RouteLocationSuggestion> onSel) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: sug.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Nenhuma cidade encontrada.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                ),
              )
            : Column(
                children: [
                  for (int i = 0; i < sug.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, color: Color(0xFFF1F5F9)),
                    InkWell(
                      onTap: () => onSel(sug[i]),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        child: Row(
                          children: [
                            const Icon(Icons.location_on_outlined,
                                size: 18, color: Color(0xFF3B82F6)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    sug[i].name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      color: Color(0xFF1F2937),
                                    ),
                                  ),
                                  if (sug[i].subtitle.isNotEmpty)
                                    Text(
                                      sug[i].subtitle,
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF6B7280)),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildCitySelector() {
    final h = (_allCities.length * 76.0).clamp(160.0, 280.0).toDouble();
    return Container(
        decoration: BoxDecoration(
            color: _surface(context),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.06),
                  blurRadius: 10,
                  offset: const Offset(0, 2))
            ]),
        child: Column(children: [
          InkWell(
              onTap: () => _toggleSelectAll(!_selectAll),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(20)),
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Row(children: [
                    AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                            color: _selectAll
                                ? const Color(0xFF2563EB)
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color: _selectAll
                                    ? const Color(0xFF2563EB)
                                    : const Color(0xFFCBD5E1),
                                width: 1.5)),
                        child: _selectAll
                            ? const Icon(Icons.check,
                                color: Colors.white, size: 14)
                            : null),
                    const SizedBox(width: 10),
                    const Text('Todas as cidades',
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: Color(0xFF1F2937))),
                    const Spacer(),
                    Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(20)),
                        child: Text('${_allCities.length} cidades',
                            style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF2563EB),
                                fontWeight: FontWeight.w500))),
                    const SizedBox(width: 6),
                    IconButton(
                        onPressed: () =>
                            setState(() => _showCitySelector = false),
                        tooltip: 'Fechar lista',
                        icon: const Icon(Icons.close_rounded,
                            size: 18, color: Color(0xFF6B7280)),
                        style: IconButton.styleFrom(
                            minimumSize: const Size(30, 30),
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap)),
                  ]))),
          const Divider(height: 1, color: Color(0xFFF1F5F9)),
          ConstrainedBox(
              constraints: BoxConstraints(maxHeight: h),
              child: Scrollbar(
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                          children: _allCities
                              .asMap()
                              .entries
                              .map((e) => Padding(
                                  padding: EdgeInsets.only(
                                      bottom: e.key < _allCities.length - 1
                                          ? 8
                                          : 0),
                                  child: _CitySelectionChip(
                                      city: e.value,
                                      selected: _selectedCityNames
                                          .contains(e.value.city),
                                      tempUnit: _tempUnit,
                                      onChanged: (v) =>
                                          _toggleCity(e.value.city, v))))
                              .toList())))),
          if (_selectedCityNames.isEmpty)
            Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text('Selecione ao menos uma cidade',
                    style: TextStyle(
                        fontSize: 12, color: Colors.orange.shade700))),
        ]));
  }

  Widget _buildMapCard() {
    final fb = _visibleCities.map((c) => LatLng(c.lat, c.lng)).toList();
    final mp = _routePolyline.length >= 2 ? _routePolyline : fb;
    final mc = _visibleCities.isNotEmpty ? _visibleCities : _allCities;
    final bs =
        mp.isNotEmpty ? mp : mc.map((c) => LatLng(c.lat, c.lng)).toList();
    return Container(
        decoration: BoxDecoration(
            color: _surface(context),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 3))
            ]),
        child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
                height: 260,
                child: bs.length < 2
                    ? Container(
                        decoration: const BoxDecoration(
                            gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                              Color(0xFFE0F2FE),
                              Color(0xFFF0FDF4)
                            ])),
                        child: const Center(
                            child: Text(
                                'Sem pontos suficientes para desenhar a rota',
                                style: TextStyle(
                                    color: Color(0xFF475569),
                                    fontWeight: FontWeight.w500))))
                    : FlutterMap(
                        options: MapOptions(
                            initialCameraFit: CameraFit.bounds(
                                bounds: LatLngBounds.fromPoints(bs),
                                padding: const EdgeInsets.all(24)),
                            interactionOptions: const InteractionOptions(
                                flags: InteractiveFlag.drag |
                                    InteractiveFlag.pinchZoom |
                                    InteractiveFlag.doubleTapZoom)),
                        children: [
                            TileLayer(
                                urlTemplate:
                                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'com.skycast.app'),
                            if (mp.length >= 2)
                              PolylineLayer(polylines: [
                                Polyline(
                                    points: mp,
                                    strokeWidth: 5,
                                    color: const Color(0xFF2563EB)
                                        .withOpacity(0.85))
                              ]),
                            MarkerLayer(markers: [
                              ...mc.map((city) {
                                final st = _cityStatuses[city.city];
                                final isCur = st == CityStatus.current,
                                    isPas = st == CityStatus.passed;
                                final dc = isCur
                                    ? const Color(0xFFF59E0B)
                                    : isPas
                                        ? const Color(0xFF6B7280)
                                        : city.isOrigin
                                            ? const Color(0xFF1D4ED8)
                                            : city.isDestination
                                                ? const Color(0xFF065F46)
                                                : const Color(0xFF0EA5E9);
                                final sz = isCur
                                    ? 14.0
                                    : city.isOrigin || city.isDestination
                                        ? 11.0
                                        : 9.0;
                                return Marker(
                                    point: LatLng(city.lat, city.lng),
                                    width: sz * 2,
                                    height: sz * 2,
                                    alignment: Alignment.center,
                                    child: Container(
                                        width: sz * 2,
                                        height: sz * 2,
                                        decoration: BoxDecoration(
                                            color: dc,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                                color: Colors.white, width: 2),
                                            boxShadow: [
                                              BoxShadow(
                                                  color: dc.withOpacity(
                                                      isCur ? 0.55 : 0.3),
                                                  blurRadius: isCur ? 10 : 4,
                                                  spreadRadius: isCur ? 2 : 0)
                                            ]),
                                        child: isCur
                                            ? const Icon(Icons.navigation,
                                                color: Colors.white, size: 12)
                                            : isPas
                                                ? const Icon(Icons.check,
                                                    color: Colors.white,
                                                    size: 9)
                                                : null));
                              }),
                              if (_currentPosition != null && _tripStarted)
                                Marker(
                                    point: LatLng(_currentPosition!.latitude,
                                        _currentPosition!.longitude),
                                    width: 20,
                                    height: 20,
                                    alignment: Alignment.center,
                                    child: Container(
                                        width: 20,
                                        height: 20,
                                        decoration: BoxDecoration(
                                            color: const Color(0xFF2563EB),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                                color: Colors.white,
                                                width: 2.5),
                                            boxShadow: [
                                              BoxShadow(
                                                  color: const Color(0xFF2563EB)
                                                      .withOpacity(0.4),
                                                  blurRadius: 8)
                                            ]))),
                            ]),
                            RichAttributionWidget(attributions: [
                              TextSourceAttribution(
                                  'OpenStreetMap contributors',
                                  onTap: () {})
                            ]),
                            if (_trafficLoading)
                              const Align(
                                  alignment: Alignment.topRight,
                                  child: Padding(
                                      padding: EdgeInsets.all(10),
                                      child: DecoratedBox(
                                          decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.all(
                                                  Radius.circular(10))),
                                          child: Padding(
                                              padding: EdgeInsets.symmetric(
                                                  horizontal: 10, vertical: 6),
                                              child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    SizedBox(
                                                        width: 12,
                                                        height: 12,
                                                        child:
                                                            CircularProgressIndicator(
                                                                strokeWidth:
                                                                    2)),
                                                    SizedBox(width: 8),
                                                    Text('Trânsito')
                                                  ]))))),
                            if (!_trafficLoading)
                              Align(
                                  alignment: Alignment.topLeft,
                                  child: Padding(
                                      padding: const EdgeInsets.all(10),
                                      child: Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 10, vertical: 8),
                                          decoration: BoxDecoration(
                                              color: _surface(context),
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              boxShadow: [
                                                BoxShadow(
                                                    color: Colors.black
                                                        .withOpacity(0.08),
                                                    blurRadius: 6)
                                              ]),
                                          child: const Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text('Trânsito',
                                                    style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color:
                                                            Color(0xFF334155))),
                                                SizedBox(height: 4),
                                                Text(
                                                    'Detalhes por cidade nos cards expandidos.',
                                                    style: TextStyle(
                                                        fontSize: 10.5,
                                                        color:
                                                            Color(0xFF334155))),
                                                SizedBox(height: 8),
                                                Text(
                                                    'Trânsito consultado via backend.',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color:
                                                            Color(0xFF9CA3AF))),
                                              ])))),
                          ]))));
  }

  Widget _buildCityCards() {
    if (_visibleCities.isEmpty)
      return Container(
          padding: const EdgeInsets.all(24),
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: _surface(context),
              borderRadius: BorderRadius.circular(16)),
          child: const Text('Nenhuma cidade selecionada',
              style: TextStyle(color: Color(0xFF9CA3AF))));
    final h = (_visibleCities.length * 142.0).clamp(220.0, 480.0).toDouble();
    return SizedBox(
        height: h,
        child: Scrollbar(
            thumbVisibility: true,
            child: SingleChildScrollView(
                child: Stack(children: [
              Positioned(
                  left: 18,
                  top: 20,
                  bottom: 20,
                  child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                            const Color(0xFF3B82F6).withOpacity(0.3),
                            const Color(0xFF06B6D4).withOpacity(0.3)
                          ])))),
              Column(
                  children: _visibleCities
                      .asMap()
                      .entries
                      .map((e) => Padding(
                          padding: EdgeInsets.only(
                              bottom:
                                  e.key < _visibleCities.length - 1 ? 12 : 0),
                          child: _RouteCityCard(
                              city: e.value,
                              tempUnit: _tempUnit,
                              tripStatus: (_tripStarted || _tripFinished)
                                  ? _cityStatuses[e.value.city]
                                  : null)))
                      .toList()),
            ]))));
  }

  Widget _sectionTitle(String t) => Text(t,
      style: const TextStyle(
          fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)));

  Widget _gradBtn(
          {required VoidCallback onTap,
          required Widget child,
          required List<Color> colors,
          double h = 48}) =>
      GestureDetector(
          onTap: onTap,
          child: Container(
              height: h,
              decoration: BoxDecoration(
                  gradient: LinearGradient(colors: colors),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                        color: colors.first.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 4))
                  ]),
              child: Center(child: child)));
}
