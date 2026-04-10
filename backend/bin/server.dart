import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

const Duration _reverseCacheTtl = Duration(minutes: 30);

final Map<String, ({DateTime createdAt, Map<String, dynamic> value})>
    _reverseCache = {};

String _reverseCacheKey(double lat, double lon, String lang, String zoom) {
  // 3 casas decimais reduz volume de chamadas e segue suficiente para cidade.
  final kLat = (lat * 1000).round() / 1000;
  final kLon = (lon * 1000).round() / 1000;
  return '$kLat,$kLon|$lang|$zoom';
}

Future<void> main() async {
  final env = dotenv.DotEnv(includePlatformEnvironment: true);
  try {
    env.load();
  } catch (_) {
    // Permite subir somente com variaveis de ambiente (ex.: Docker/CI).
  }
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  final host = (env['HOST'] ?? '127.0.0.1').trim();
  final tomTomKey = (env['TOMTOM_API_KEY'] ?? '').trim();

  final app = Router()
    ..get('/openapi.yaml', (Request req) async {
      final spec = await _readOpenApiSpec();
      return Response.ok(spec, headers: {'content-type': 'application/yaml'});
    })
    ..get('/docs', (Request req) {
      return Response.ok(_swaggerHtml(),
          headers: {'content-type': 'text/html; charset=utf-8'});
    })
    ..get('/health', (Request req) {
      return _json({'ok': true, 'service': 'skycast-backend'});
    })
    ..get('/api/geocode', (Request req) async {
      final qp = req.url.queryParameters;
      final name = (qp['name'] ?? '').trim();
      final count = qp['count'] ?? '1';
      final lang = qp['lang'] ?? 'pt';
      if (name.isEmpty) {
        return _json({'error': 'Parametro name e obrigatorio'}, status: 400);
      }

      final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
        'name': name,
        'count': count,
        'language': lang,
        'format': 'json',
      });

      return _proxyGet(uri);
    })
    ..get('/api/reverse', (Request req) async {
      final qp = req.url.queryParameters;
      final lat = qp['lat'];
      final lon = qp['lon'];
      final lang = qp['lang'] ?? 'pt';
      final zoom = qp['zoom'] ?? '10';
      if (lat == null || lon == null) {
        return _json({'error': 'Parametros lat e lon sao obrigatorios'},
            status: 400);
      }

      final latN = double.tryParse(lat);
      final lonN = double.tryParse(lon);
      if (latN == null || lonN == null) {
        return _json({'error': 'lat/lon invalidos'}, status: 400);
      }

      final cacheKey = _reverseCacheKey(latN, lonN, lang, zoom);
      final cached = _reverseCache[cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.createdAt) <= _reverseCacheTtl) {
        return _json(cached.value);
      }

      if (tomTomKey.isNotEmpty && !tomTomKey.startsWith('YOUR_')) {
        final tomTomAddress = await _tryTomTomReverse(latN, lonN,
            lang: lang, tomTomKey: tomTomKey);
        if (tomTomAddress != null) {
          _reverseCache[cacheKey] = (
            createdAt: DateTime.now(),
            value: tomTomAddress,
          );
          return _json(tomTomAddress);
        }
      }

      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': lat,
        'lon': lon,
        'format': 'json',
        'zoom': zoom,
        'accept-language': lang,
      });

      final nominatim = await _proxyGetWithRetry429(uri,
          headers: {'User-Agent': 'SkyCastBackend/1.0'});

      if (nominatim.statusCode == 200) {
        try {
          final parsed = jsonDecode(await nominatim.readAsString())
              as Map<String, dynamic>?;
          if (parsed != null) {
            _reverseCache[cacheKey] = (
              createdAt: DateTime.now(),
              value: parsed,
            );
            return _json(parsed);
          }
        } catch (_) {}
      }

      return nominatim;
    })
    ..get('/api/route', (Request req) async {
      final qp = req.url.queryParameters;
      final fromLat = qp['fromLat'];
      final fromLon = qp['fromLon'];
      final toLat = qp['toLat'];
      final toLon = qp['toLon'];
      if ([fromLat, fromLon, toLat, toLon].contains(null)) {
        return _json(
            {'error': 'fromLat, fromLon, toLat e toLon sao obrigatorios'},
            status: 400);
      }

      // Tenta TomTom primeiro
      final tomTomRoute = await _tryTomTomRoute(
        fromLat: fromLat!,
        fromLon: fromLon!,
        toLat: toLat!,
        toLon: toLon!,
        tomTomKey: tomTomKey,
      );
      if (tomTomRoute != null) return _json(tomTomRoute);

      // Fallback OSRM — timeout maior e trata erro explicitamente
      try {
        final path = '/route/v1/driving/$fromLon,$fromLat;$toLon,$toLat';
        final uri = Uri.https('router.project-osrm.org', path, {
          'overview': 'full',
          'geometries': 'geojson',
          'steps': 'false',
          'alternatives': 'true',
        });
        final r = await http
            .get(uri)
            .timeout(const Duration(seconds: 20)); // ← era 15s via _proxyGet
        if (r.statusCode != 200) {
          return _json({'error': 'OSRM retornou ${r.statusCode}', 'routes': []},
              status: 502);
        }
        return Response(r.statusCode,
            body: r.body, headers: {'content-type': 'application/json'});
      } catch (e) {
        // Retorna routes vazio em vez de 502 — o Flutter lida com isso graciosamente
        return _json({'code': 'Ok', 'routes': []});
      }
    })
    ..get('/api/weather', (Request req) async {
      final qp = req.url.queryParameters;
      final lat = qp['lat'];
      final lon = qp['lon'];
      final timezone = qp['timezone'] ?? 'auto';
      if (lat == null || lon == null) {
        return _json({'error': 'Parametros lat e lon sao obrigatorios'},
            status: 400);
      }

      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': lat,
        'longitude': lon,
        'current':
            'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,surface_pressure',
        'daily':
            'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
        'hourly':
            'temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,wind_speed_10m',
        'timezone': timezone,
        'past_days': '1',
        'forecast_days': '10',
      });

      return _proxyGet(uri);
    })
    ..get('/api/traffic', (Request req) async {
      final qp = req.url.queryParameters;
      final lat = qp['lat'];
      final lon = qp['lon'];
      if (lat == null || lon == null) {
        return _json({'error': 'Parametros lat e lon sao obrigatorios'},
            status: 400);
      }
      if (tomTomKey.isEmpty || tomTomKey.startsWith('YOUR_')) {
        return _json({
          'error': 'TOMTOM_API_KEY nao configurada no backend',
          'detail':
              'Defina TOMTOM_API_KEY valida no ambiente do container/servidor.'
        }, status: 500);
      }

      final uri = Uri.https(
        'api.tomtom.com',
        '/traffic/services/4/flowSegmentData/absolute/10/json',
        {
          'point': '$lat,$lon',
          'unit': 'KMPH',
          'openLr': 'false',
          'key': tomTomKey,
        },
      );

      return _proxyGet(uri);
    });

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_cors())
      .addHandler(app.call);

  final server = await _bindWithFallback(handler, host: host, basePort: port);
  stdout.writeln(
      'SkyCast backend rodando em http://${server.address.address}:${server.port}');
}

Future<HttpServer> _bindWithFallback(Handler handler,
    {required String host, required int basePort}) async {
  Object? lastError;
  for (int i = 0; i < 8; i++) {
    final p = basePort + i;
    try {
      return await io.serve(handler, host, p);
    } on SocketException catch (e) {
      lastError = e;
      stderr.writeln('Falha ao abrir $host:$p -> $e');
    }
  }
  throw Exception(
      'Nao foi possivel abrir o servidor a partir da porta $basePort em $host. Ultimo erro: $lastError');
}

Middleware _cors() {
  return (Handler inner) {
    return (Request req) async {
      if (req.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders());
      }
      final res = await inner(req);
      return res.change(headers: {...res.headers, ..._corsHeaders()});
    };
  };
}

Map<String, String> _corsHeaders() => {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Origin, Content-Type, Authorization',
    };

Future<Response> _proxyGet(Uri uri, {Map<String, String>? headers}) async {
  try {
    final r = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 15));

    final contentType = r.headers['content-type'] ?? 'application/json';
    return Response(
      r.statusCode,
      body: r.body,
      headers: {'content-type': contentType},
    );
  } catch (e) {
    return _json(
        {'error': 'Falha ao consultar servico externo', 'detail': '$e'},
        status: 502);
  }
}

Future<Response> _proxyGetWithRetry429(Uri uri,
    {Map<String, String>? headers}) async {
  const retryDelays = [Duration(milliseconds: 700), Duration(seconds: 2)];

  for (int attempt = 0; attempt <= retryDelays.length; attempt++) {
    final res = await _proxyGet(uri, headers: headers);
    if (res.statusCode != 429 || attempt == retryDelays.length) {
      return res;
    }
    await Future.delayed(retryDelays[attempt]);
  }

  return _json({'error': 'Falha ao consultar servico externo'}, status: 502);
}

Response _json(Map<String, dynamic> body, {int status = 200}) {
  return Response(
    status,
    body: jsonEncode(body),
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Future<String> _readOpenApiSpec() async {
  final local = File('openapi.yaml');
  if (await local.exists()) {
    return local.readAsString();
  }
  final fallback = File('backend/openapi.yaml');
  if (await fallback.exists()) {
    return fallback.readAsString();
  }
  return 'openapi: 3.0.3\ninfo:\n  title: SkyCast API\n  version: 1.0.0\n';
}

String _swaggerHtml() => '''
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>SkyCast API Docs</title>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css" />
    <style>
      body { margin: 0; background: #fafafa; }
      #swagger-ui { max-width: 1200px; margin: 0 auto; }
    </style>
  </head>
  <body>
    <div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>
      window.ui = SwaggerUIBundle({
        url: '/openapi.yaml',
        dom_id: '#swagger-ui',
        deepLinking: true,
        displayRequestDuration: true,
      });
    </script>
  </body>
</html>
''';

Future<Map<String, dynamic>?> _tryTomTomReverse(
  double lat,
  double lon, {
  required String lang,
  required String tomTomKey,
}) async {
  try {
    final uri =
        Uri.https('api.tomtom.com', '/search/2/reverseGeocode/$lat,$lon.json', {
      'key': tomTomKey,
      'language': lang,
      'radius': '12000',
      'returnSpeedLimit': 'false',
      'allowFreeformNewline': 'false',
    });

    final res = await http.get(uri).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return null;

    final body = jsonDecode(res.body) as Map<String, dynamic>?;
    final addresses = (body?['addresses'] as List?) ?? const [];
    if (addresses.isEmpty) return null;

    final first = addresses.first as Map<String, dynamic>?;
    final address = first?['address'] as Map<String, dynamic>?;
    if (address == null) return null;

    final municipality = (address['municipality'] as String?)?.trim();
    final subMunicipality =
        (address['municipalitySubdivision'] as String?)?.trim();
    final country = (address['country'] as String?)?.trim() ?? 'Brasil';
    final city = municipality?.isNotEmpty == true
        ? municipality!
        : (subMunicipality?.isNotEmpty == true ? subMunicipality! : null);
    if (city == null || city.isEmpty) return null;

    // Mantem formato semelhante ao Nominatim para nao quebrar o Flutter.
    return {
      'lat': '$lat',
      'lon': '$lon',
      'address': {
        'city': city,
        'municipality': municipality ?? city,
        'country': country,
      }
    };
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _tryTomTomRoute({
  required String fromLat,
  required String fromLon,
  required String toLat,
  required String toLon,
  required String tomTomKey,
}) async {
  if (tomTomKey.isEmpty || tomTomKey.startsWith('YOUR_')) {
    return null;
  }

  try {
    final path =
        '/routing/1/calculateRoute/$fromLat,$fromLon:$toLat,$toLon/json';
    final uri = Uri.https('api.tomtom.com', path, {
      'traffic': 'true',
      'travelMode': 'car',
      'routeType': 'fastest',
      'computeBestOrder': 'false',
      'maxAlternatives': '2',
      'language': 'pt-BR',
      'sectionType': 'traffic',
      'key': tomTomKey,
    });

    final res = await http.get(uri).timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) return null;

    final body = jsonDecode(res.body) as Map<String, dynamic>?;
    final routes = (body?['routes'] as List?) ?? const [];
    if (routes.isEmpty) return null;

    final normalized = <Map<String, dynamic>>[];

    for (final raw in routes) {
      final route = raw as Map<String, dynamic>?;
      if (route == null) continue;

      final summary = route['summary'] as Map<String, dynamic>?;
      final legs = (route['legs'] as List?) ?? const [];
      if (summary == null || legs.isEmpty) continue;

      final coords = <List<double>>[];
      for (final legRaw in legs) {
        final leg = legRaw as Map?;
        final points = (leg?['points'] as List?) ?? const [];
        for (final p in points) {
          final m = p as Map?;
          final lat = (m?['latitude'] as num?)?.toDouble();
          final lon = (m?['longitude'] as num?)?.toDouble();
          if (lat == null || lon == null) continue;
          final current = [lon, lat];
          if (coords.isEmpty ||
              coords.last[0] != current[0] ||
              coords.last[1] != current[1]) {
            coords.add(current);
          }
        }
      }

      if (coords.length < 2) continue;

      final lengthMeters = (summary['lengthInMeters'] as num?)?.toDouble() ?? 0;
      final travelSeconds =
          (summary['travelTimeInSeconds'] as num?)?.toDouble() ?? 0;
      final trafficSeconds =
          (summary['trafficDelayInSeconds'] as num?)?.toDouble() ?? 0;

      normalized.add({
        'distance': lengthMeters,
        'duration': travelSeconds,
        'trafficDelayInSeconds': trafficSeconds,
        'geometry': {
          'coordinates': coords,
        }
      });
    }

    if (normalized.isEmpty) return null;

    return {
      'code': 'Ok',
      'routes': normalized,
    };
  } catch (_) {
    return null;
  }
}
