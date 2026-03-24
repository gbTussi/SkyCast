import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

void main() {
  runApp(const SkyCastApp());
}

// ─────────────────────────────────────────────
// Modelos
// ─────────────────────────────────────────────

enum WeatherCondition { sunny, partly, cloudy, rainy, stormy, snowy }

extension WeatherConditionX on WeatherCondition {
  String get emoji {
    switch (this) {
      case WeatherCondition.sunny:
        return '☀️';
      case WeatherCondition.partly:
        return '⛅';
      case WeatherCondition.cloudy:
        return '☁️';
      case WeatherCondition.rainy:
        return '🌧️';
      case WeatherCondition.stormy:
        return '⛈️';
      case WeatherCondition.snowy:
        return '❄️';
    }
  }

  String get label {
    switch (this) {
      case WeatherCondition.sunny:
        return 'Ensolarado';
      case WeatherCondition.partly:
        return 'Parcialmente nublado';
      case WeatherCondition.cloudy:
        return 'Nublado';
      case WeatherCondition.rainy:
        return 'Chuvoso';
      case WeatherCondition.stormy:
        return 'Tempestade';
      case WeatherCondition.snowy:
        return 'Nevando';
    }
  }

  List<Color> get gradient {
    switch (this) {
      case WeatherCondition.sunny:
        return [const Color(0xFFf97316), const Color(0xFFfbbf24)];
      case WeatherCondition.partly:
        return [const Color(0xFF3b82f6), const Color(0xFF60a5fa)];
      case WeatherCondition.cloudy:
        return [const Color(0xFF64748b), const Color(0xFF94a3b8)];
      case WeatherCondition.rainy:
        return [const Color(0xFF1d4ed8), const Color(0xFF3b82f6)];
      case WeatherCondition.stormy:
        return [const Color(0xFF1e1b4b), const Color(0xFF4338ca)];
      case WeatherCondition.snowy:
        return [const Color(0xFF7dd3fc), const Color(0xFFe0f2fe)];
    }
  }
}

WeatherCondition conditionFromCode(int? code) {
  if (code == null) return WeatherCondition.cloudy;
  if (code == 0) return WeatherCondition.sunny;
  if ([1, 2, 3].contains(code)) return WeatherCondition.partly;
  if ([45, 48].contains(code)) return WeatherCondition.cloudy;
  if ([51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82].contains(code)) {
    return WeatherCondition.rainy;
  }
  if ([71, 73, 75, 77].contains(code)) return WeatherCondition.snowy;
  if ([95, 96, 99].contains(code)) return WeatherCondition.stormy;
  return WeatherCondition.cloudy;
}

class WeatherData {
  const WeatherData({
    required this.temperature,
    required this.feelsLike,
    required this.humidity,
    required this.windSpeed,
    required this.condition,
    this.pressure = 1013,
    this.visibility = 10,
    this.forecast = const [],
  });

  final double temperature;
  final double feelsLike;
  final int humidity;
  final double windSpeed;
  final WeatherCondition condition;
  final int pressure;
  final int visibility;
  final List<DayForecast> forecast;
}

class DayForecast {
  const DayForecast({
    required this.label,
    required this.condition,
    required this.min,
    required this.max,
    required this.precipChance,
  });

  final String label;
  final WeatherCondition condition;
  final int min;
  final int max;
  final int precipChance;
}

class LocationResult {
  const LocationResult({
    required this.name,
    required this.country,
    required this.admin1,
    required this.latitude,
    required this.longitude,
  });

  final String name;
  final String country;
  final String? admin1;
  final double latitude;
  final double longitude;

  String get displayName => admin1 != null ? '$name, $admin1' : name;
}

// ─────────────────────────────────────────────
// App
// ─────────────────────────────────────────────

class SkyCastApp extends StatelessWidget {
  const SkyCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkyCast',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

// ─────────────────────────────────────────────
// HomePage
// ─────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  bool _loading = true;
  String? _error;
  String _locationLabel = 'Obtendo localização...';
  WeatherData? _weather;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  List<LocationResult> _suggestions = [];
  bool _searchLoading = false;
  bool _showSuggestions = false;
  Timer? _debounce;

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  static const _dayLabels = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _carregarPorGPS();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _debounce?.cancel();
    _fadeCtrl.dispose();
    super.dispose();
  }

  // ── GPS ─────────────────────────────────────

  Future<String> _reverseGeocode(double lat, double lon) async {
    try {
      final uri = Uri.https(
        'nominatim.openstreetmap.org',
        '/reverse',
        {
          'lat': lat.toString(),
          'lon': lon.toString(),
          'format': 'json',
          'accept-language': 'pt',
        },
      );
      final response = await http.get(uri, headers: {
        'User-Agent': 'SkyCastApp/1.0',
      }).timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final city = address['city'] as String? ??
              address['town'] as String? ??
              address['village'] as String? ??
              address['municipality'] as String?;
          final state = address['state'] as String?;
          if (city != null) {
            return state != null ? '$city, $state' : city;
          }
        }
      }
    } catch (_) {}
    return '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}';
  }

  Future<void> _carregarPorGPS() async {
    setState(() {
      _loading = true;
      _error = null;
      _showSuggestions = false;
      _locationLabel = 'Obtendo localização...';
    });

    try {
      final position = await _obterLocalizacao();
      _locationLabel =
          await _reverseGeocode(position.latitude, position.longitude);
      final weather = await _buscarClima(
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (!mounted) return;
      setState(() => _weather = weather);
      _fadeCtrl
        ..reset()
        ..forward();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<Position> _obterLocalizacao() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) throw Exception('Ative o GPS para continuar.');

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw Exception('Permissão de localização negada.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Permissão negada permanentemente.');
    }

    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 15),
    );
  }

  // ── Geocoding ────────────────────────────────

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _buscarLocais(query.trim());
    });
  }

  Future<void> _buscarLocais(String query) async {
    setState(() => _searchLoading = true);
    try {
      final uri = Uri.https(
        'geocoding-api.open-meteo.com',
        '/v1/search',
        {'name': query, 'count': '8', 'language': 'pt', 'format': 'json'},
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        setState(() {
          _suggestions = [];
          _showSuggestions = false;
        });
        return;
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final results = data['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) {
        setState(() {
          _suggestions = [];
          _showSuggestions = true;
        });
        return;
      }
      final locations = results.map((r) {
        final m = r as Map<String, dynamic>;
        return LocationResult(
          name: m['name'] as String? ?? '',
          country: m['country'] as String? ?? '',
          admin1: m['admin1'] as String?,
          latitude: (m['latitude'] as num).toDouble(),
          longitude: (m['longitude'] as num).toDouble(),
        );
      }).toList();
      if (!mounted) return;
      setState(() {
        _suggestions = locations;
        _showSuggestions = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
    } finally {
      if (!mounted) return;
      setState(() => _searchLoading = false);
    }
  }

  Future<void> _selecionarLocal(LocationResult location) async {
    _searchController.text = location.name;
    _searchFocus.unfocus();
    setState(() {
      _showSuggestions = false;
      _loading = true;
      _error = null;
      _locationLabel = location.displayName;
    });
    try {
      final weather = await _buscarClima(
        latitude: location.latitude,
        longitude: location.longitude,
      );
      if (!mounted) return;
      setState(() => _weather = weather);
      _fadeCtrl
        ..reset()
        ..forward();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  // ── Clima ────────────────────────────────────

  Future<WeatherData> _buscarClima({
    required double latitude,
    required double longitude,
  }) async {
    final uri = Uri.https(
      'api.open-meteo.com',
      '/v1/forecast',
      {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current':
            'temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,surface_pressure',
        'daily':
            'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
        'timezone': 'auto',
        'forecast_days': '10',
      },
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Não foi possível consultar o clima agora.');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final current = data['current'] as Map<String, dynamic>?;
    if (current == null) throw Exception('Resposta inválida.');

    final daily = data['daily'] as Map<String, dynamic>?;
    final List<DayForecast> forecast = [];
    if (daily != null) {
      final times = daily['time'] as List<dynamic>? ?? [];
      final codes = daily['weather_code'] as List<dynamic>? ?? [];
      final maxTemps = daily['temperature_2m_max'] as List<dynamic>? ?? [];
      final minTemps = daily['temperature_2m_min'] as List<dynamic>? ?? [];
      final precip =
          daily['precipitation_probability_max'] as List<dynamic>? ?? [];
      for (int i = 0; i < times.length; i++) {
        final date = DateTime.tryParse(times[i] as String? ?? '');
        String label;
        if (i == 0) {
          label = 'Hoje';
        } else if (i == 1) {
          label = 'Amanhã';
        } else {
          label = date != null ? _dayLabels[date.weekday % 7] : '---';
        }
        forecast.add(DayForecast(
          label: label,
          condition: conditionFromCode((codes[i] as num?)?.toInt()),
          max: (maxTemps[i] as num?)?.round() ?? 0,
          min: (minTemps[i] as num?)?.round() ?? 0,
          precipChance: (precip[i] as num?)?.toInt() ?? 0,
        ));
      }
    }

    return WeatherData(
      temperature: (current['temperature_2m'] as num?)?.toDouble() ?? 0,
      feelsLike: (current['apparent_temperature'] as num?)?.toDouble() ?? 0,
      humidity: (current['relative_humidity_2m'] as num?)?.toInt() ?? 0,
      windSpeed: (current['wind_speed_10m'] as num?)?.toDouble() ?? 0,
      condition: conditionFromCode((current['weather_code'] as num?)?.toInt()),
      pressure: (current['surface_pressure'] as num?)?.round() ?? 1013,
      forecast: forecast,
    );
  }

  // ── Build ────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final weather = _weather;
    final condition = weather?.condition ?? WeatherCondition.partly;
    final gradient = condition.gradient;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: GestureDetector(
        onTap: () {
          _searchFocus.unfocus();
          setState(() => _showSuggestions = false);
        },
        child: Scaffold(
          body: AnimatedContainer(
            duration: const Duration(milliseconds: 800),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient,
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  // Header
                  _buildHeader(),

                  // Scrollable content
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _carregarPorGPS,
                      color: Colors.white,
                      backgroundColor: Colors.white.withOpacity(0.2),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          // Search bar
                          _buildSearchBar(),
                          const SizedBox(height: 16),

                          if (_loading && weather == null)
                            _buildLoadingHero()
                          else ...[
                            // Hero temperatura
                            FadeTransition(
                              opacity: _fadeAnim,
                              child: _buildHero(weather, condition),
                            ),
                            const SizedBox(height: 16),

                            // Stats grid
                            if (weather != null)
                              FadeTransition(
                                opacity: _fadeAnim,
                                child: _buildStatsGrid(weather),
                              ),
                            const SizedBox(height: 16),

                            // Previsão 10 dias
                            if (weather != null && weather.forecast.isNotEmpty)
                              FadeTransition(
                                opacity: _fadeAnim,
                                child: _buildForecast(weather),
                              ),

                            // Erro
                            if (_error != null) ...[
                              const SizedBox(height: 16),
                              _buildErrorCard(),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: Text(
              'SkyCast',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 1,
                shadows: [
                  Shadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
          ),
          // GPS button
          _GlassButton(
            onTap: _loading ? null : _carregarPorGPS,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.my_location, color: Colors.white, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.3)),
          ),
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocus,
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Buscar cidade...',
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.55)),
              prefixIcon:
                  const Icon(Icons.search, color: Colors.white70, size: 20),
              suffixIcon: _searchLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      ),
                    )
                  : _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close,
                              color: Colors.white70, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _onSearchChanged('');
                          },
                        )
                      : null,
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),
        ),
        if (_showSuggestions) _buildSuggestionsList(),
      ],
    );
  }

  Widget _buildSuggestionsList() {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.15),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _suggestions.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Nenhuma cidade encontrada.',
                  style: TextStyle(color: Colors.black54),
                ),
              )
            : Column(
                children: [
                  for (int i = 0; i < _suggestions.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    InkWell(
                      onTap: () => _selecionarLocal(_suggestions[i]),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        child: Row(
                          children: [
                            const Icon(Icons.location_on_outlined,
                                size: 18, color: Color(0xFF3b82f6)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _suggestions[i].name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  Text(
                                    [
                                      if (_suggestions[i].admin1 != null)
                                        _suggestions[i].admin1!,
                                      _suggestions[i].country,
                                    ].join(', '),
                                    style: const TextStyle(
                                        fontSize: 12, color: Colors.black45),
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

  Widget _buildLoadingHero() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 80),
      child: Center(
        child: Column(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                  color: Colors.white, strokeWidth: 2.5),
            ),
            SizedBox(height: 16),
            Text(
              'Obtendo localização...',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero(WeatherData? weather, WeatherCondition condition) {
    return Column(
      children: [
        const SizedBox(height: 8),
        // Localização
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_on, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                _locationLabel,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.85),
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),

        // Temperatura principal
        Text(
          weather != null ? '${weather.temperature.round()}°' : '--°',
          style: TextStyle(
            fontSize: 96,
            fontWeight: FontWeight.w200,
            color: Colors.white,
            height: 1.0,
            shadows: [
              Shadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
              ),
            ],
          ),
        ),

        // Condição
        Text(
          condition.label,
          style: const TextStyle(
            fontSize: 20,
            color: Colors.white,
            fontWeight: FontWeight.w300,
            letterSpacing: 0.5,
          ),
        ),

        const SizedBox(height: 6),

        if (weather != null && weather.forecast.isNotEmpty)
          Text(
            'Máx. ${weather.forecast[0].max}°  •  Mín. ${weather.forecast[0].min}°',
            style:
                TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
          ),

        if (weather != null)
          Text(
            'Sensação térmica ${weather.feelsLike.round()}°',
            style:
                TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
          ),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildStatsGrid(WeatherData weather) {
    final stats = [
      (Icons.water_drop, 'Umidade', '${weather.humidity}%'),
      (Icons.air, 'Vento', '${weather.windSpeed.round()} km/h'),
      (Icons.visibility, 'Visibilidade', '${weather.visibility} km'),
      (Icons.speed, 'Pressão', '${weather.pressure}'),
    ];

    return Row(
      children: stats.map((s) {
        return Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: Colors.white.withOpacity(0.2), width: 0.5),
            ),
            child: Column(
              children: [
                Icon(s.$1, color: Colors.white70, size: 18),
                const SizedBox(height: 6),
                Text(
                  s.$3,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  s.$2,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildForecast(WeatherData weather) {
    final allMins = weather.forecast.map((d) => d.min).toList();
    final allMaxs = weather.forecast.map((d) => d.max).toList();
    final globalMin = allMins.reduce(min);
    final globalMax = allMaxs.reduce(max);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.15),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withOpacity(0.2), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              'PREVISÃO PARA 10 DIAS',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const Divider(
              height: 1, color: Colors.white24, indent: 16, endIndent: 16),
          ...List.generate(weather.forecast.length, (i) {
            final day = weather.forecast[i];
            final isFirst = i == 0;
            final isLast = i == weather.forecast.length - 1;
            return Column(
              children: [
                _ForecastRow(
                  day: day,
                  globalMin: globalMin,
                  globalMax: globalMax,
                  currentTemp: isFirst ? weather.temperature : null,
                ),
                if (!isLast)
                  const Divider(
                      height: 1,
                      color: Colors.white12,
                      indent: 16,
                      endIndent: 16),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.red.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.white70, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ForecastRow
// ─────────────────────────────────────────────

class _ForecastRow extends StatelessWidget {
  const _ForecastRow({
    required this.day,
    required this.globalMin,
    required this.globalMax,
    this.currentTemp,
  });

  final DayForecast day;
  final int globalMin;
  final int globalMax;
  final double? currentTemp;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Dia
          SizedBox(
            width: 52,
            child: Text(
              day.label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
            ),
          ),

          // Emoji + chance de chuva
          SizedBox(
            width: 44,
            child: Column(
              children: [
                Text(day.condition.emoji, style: const TextStyle(fontSize: 20)),
                if (day.precipChance >= 20)
                  Text(
                    '${day.precipChance}%',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF93c5fd),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),

          // Barra min/max
          Expanded(
            child: Row(
              children: [
                Text(
                  '${day.min}°',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _TempBar(
                    min: day.min,
                    max: day.max,
                    globalMin: globalMin,
                    globalMax: globalMax,
                    current: currentTemp,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${day.max}°',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// TempBar
// ─────────────────────────────────────────────

class _TempBar extends StatelessWidget {
  const _TempBar({
    required this.min,
    required this.max,
    required this.globalMin,
    required this.globalMax,
    this.current,
  });

  final int min;
  final int max;
  final int globalMin;
  final int globalMax;
  final double? current;

  @override
  Widget build(BuildContext context) {
    final range = (globalMax - globalMin).toDouble();
    if (range <= 0) return const SizedBox(height: 6);

    final leftFrac = (min - globalMin) / range;
    final widthFrac = (max - min) / range;
    final dotFrac = current != null ? (current! - globalMin) / range : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        return SizedBox(
          height: 20,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Track
              Container(
                height: 6,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              // Fill
              Positioned(
                left: leftFrac * total,
                width: (widthFrac * total).clamp(4.0, total),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF60a5fa), Color(0xFFfbbf24)],
                    ),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              // Dot (current temp)
              if (dotFrac != null)
                Positioned(
                  left: (dotFrac * total - 5).clamp(0.0, total - 10),
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border:
                          Border.all(color: const Color(0xFFfbbf24), width: 2),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 4),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────
// GlassButton
// ─────────────────────────────────────────────

class _GlassButton extends StatelessWidget {
  const _GlassButton({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.3)),
        ),
        child: Center(child: child),
      ),
    );
  }
}
