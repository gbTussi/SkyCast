import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart' as dotenv;
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';

Future<void> main() async {
  final env = dotenv.DotEnv(includePlatformEnvironment: true);
  try {
    env.load();
  } catch (_) {
    // Permite subir somente com variaveis de ambiente (ex.: Docker/CI).
  }
  final port = int.tryParse(env['PORT'] ?? '') ?? 8080;
  final host = (env['HOST'] ?? '127.0.0.1').trim();
  final tomTomKey = env['TOMTOM_API_KEY'] ?? '';

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
      if (lat == null || lon == null) {
        return _json({'error': 'Parametros lat e lon sao obrigatorios'},
            status: 400);
      }

      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'lat': lat,
        'lon': lon,
        'format': 'json',
        'zoom': '10',
        'accept-language': lang,
      });

      return _proxyGet(uri, headers: {'User-Agent': 'SkyCastBackend/1.0'});
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

      final path = '/route/v1/driving/$fromLon,$fromLat;$toLon,$toLat';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'geometries': 'geojson',
        'steps': 'false',
      });

      return _proxyGet(uri);
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
      if (tomTomKey.isEmpty) {
        return _json({'error': 'TOMTOM_API_KEY nao configurada no backend'},
            status: 500);
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
