import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'login.dart';
import 'reset_password.dart';
import 'trip.dart';
import 'widgets/bottom_navigation.dart';

const String _backendBaseUrl = String.fromEnvironment('BACKEND_BASE_URL',
    defaultValue: 'http://10.0.2.2:8080');

Uri _backendUri(String path, [Map<String, String>? queryParameters]) {
  final base = Uri.parse(_backendBaseUrl);
  return base.replace(path: path, queryParameters: queryParameters);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const SkyCastApp());
}

// ─────────────────────────────────────────────
// SharedPrefs helper (phone + city + settings)
// ─────────────────────────────────────────────

class _Prefs {
  static const _phone = 'user_phone';
  static const _city = 'user_city';
  static const _unit = 'setting_unit'; // 'C' | 'F'
  static const _notif = 'setting_notifications'; // bool
  static const _theme = 'setting_theme'; // 'system' | 'light' | 'dark'
  static const _lang = 'setting_language'; // 'pt' | 'en'

  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static Future<String> getPhone() async => (await _p).getString(_phone) ?? '';
  static Future<void> setPhone(String v) async =>
      (await _p).setString(_phone, v);

  static Future<String> getCity() async => (await _p).getString(_city) ?? '';
  static Future<void> setCity(String v) async => (await _p).setString(_city, v);

  static Future<String> getUnit() async => (await _p).getString(_unit) ?? 'C';
  static Future<void> setUnit(String v) async => (await _p).setString(_unit, v);

  static Future<bool> getNotif() async => (await _p).getBool(_notif) ?? true;
  static Future<void> setNotif(bool v) async => (await _p).setBool(_notif, v);

  static Future<String> getTheme() async =>
      (await _p).getString(_theme) ?? 'system';
  static Future<void> setTheme(String v) async =>
      (await _p).setString(_theme, v);

  static Future<String> getLang() async => (await _p).getString(_lang) ?? 'pt';
  static Future<void> setLang(String v) async => (await _p).setString(_lang, v);
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
  if ([51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82].contains(code))
    return WeatherCondition.rainy;
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

class SkyCastApp extends StatefulWidget {
  const SkyCastApp({super.key});

  static final GlobalKey<_SkyCastAppState> _appKey =
      GlobalKey<_SkyCastAppState>();

  static Future<void> refreshSettings() async {
    await _appKey.currentState?._loadThemeMode();
  }

  static final _authRefresh =
      GoRouterRefreshStream(FirebaseAuth.instance.authStateChanges());

  static final GoRouter _router = GoRouter(
    initialLocation: '/login',
    refreshListenable: _authRefresh,
    redirect: (context, state) {
      final isLoggedIn = FirebaseAuth.instance.currentUser != null;
      final isLoggingIn = state.matchedLocation == '/login';
      if (!isLoggedIn && !isLoggingIn) return '/login';
      if (isLoggedIn && isLoggingIn) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
          path: '/reset-password',
          builder: (_, __) => const ResetPasswordScreen()),
      GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
      GoRoute(path: '/home', builder: (_, __) => const HomePage()),
      GoRoute(path: '/route', builder: (_, __) => const RouteScreen()),
      GoRoute(path: '/settings', builder: (_, __) => const SettingsScreen()),
      GoRoute(path: '/', redirect: (_, __) => '/login'),
    ],
  );

  @override
  State<SkyCastApp> createState() => _SkyCastAppState();
}

class _SkyCastAppState extends State<SkyCastApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final theme = await _Prefs.getTheme();
    if (!mounted) return;
    setState(() {
      _themeMode = switch (theme) {
        'dark' => ThemeMode.dark,
        'light' => ThemeMode.light,
        _ => ThemeMode.system,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      key: SkyCastApp._appKey,
      title: 'SkyCast',
      debugShowCheckedModeBanner: false,
      themeMode: _themeMode,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueAccent),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      routerConfig: SkyCastApp._router,
    );
  }
}

// ─────────────────────────────────────────────
// SettingsScreen
// ─────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _loading = true;

  // values
  String _unit = 'C';
  bool _notif = true;
  String _theme = 'system';
  String _lang = 'pt';

  static const _headerGradient =
      LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF06B6D4)]);

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _bg => _isDark ? const Color(0xFF0B1220) : const Color(0xFFEFF6FF);
  Color get _card => _isDark ? const Color(0xFF111827) : Colors.white;
  Color get _muted =>
      _isDark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);
  Color get _text =>
      _isDark ? const Color(0xFFE5E7EB) : const Color(0xFF1F2937);
  Color get _line =>
      _isDark ? const Color(0xFF374151) : const Color(0xFFF3F4F6);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final unit = await _Prefs.getUnit();
    final notif = await _Prefs.getNotif();
    final theme = await _Prefs.getTheme();
    final lang = await _Prefs.getLang();
    if (!mounted) return;
    setState(() {
      _unit = unit;
      _notif = notif;
      _theme = theme;
      _lang = lang;
      _loading = false;
    });
  }

  Future<void> _setUnit(String v) async {
    await _Prefs.setUnit(v);
    setState(() => _unit = v);
    _toast('Unidade de temperatura salva.');
  }

  Future<void> _setNotif(bool v) async {
    await _Prefs.setNotif(v);
    setState(() => _notif = v);
    _toast(v ? 'Notificações ativadas.' : 'Notificações desativadas.');
  }

  Future<void> _setTheme(String v) async {
    await _Prefs.setTheme(v);
    await SkyCastApp.refreshSettings();
    setState(() => _theme = v);
    _toast('Tema aplicado com sucesso.');
  }

  Future<void> _setLang(String v) async {
    await _Prefs.setLang(v);
    setState(() => _lang = v);
    _toast('Idioma salvo. Reinicie o app para aplicar.');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          // Header
          Container(
            decoration: BoxDecoration(
                gradient: _isDark
                    ? const LinearGradient(
                        colors: [Color(0xFF0F172A), Color(0xFF1E293B)])
                    : _headerGradient),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () => context.pop(),
                      child: const Icon(Icons.arrow_back_ios_new,
                          color: Colors.white, size: 20),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Configurações',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold)),
                        SizedBox(height: 4),
                        Text('Personalize sua experiência',
                            style: TextStyle(
                                color: Color(0xFFBFDBFE), fontSize: 13)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 448),
                    child: Column(
                      children: [
                        // ── Temperatura
                        _sectionCard(
                          title: 'TEMPERATURA',
                          icon: Icons.thermostat,
                          child: _segmented(
                            options: const {
                              'C': '°C  Celsius',
                              'F': '°F  Fahrenheit'
                            },
                            selected: _unit,
                            onChanged: _setUnit,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── Notificações
                        _sectionCard(
                          title: 'NOTIFICAÇÕES',
                          icon: Icons.notifications_outlined,
                          child: Column(
                            children: [
                              _switchTile(
                                label: 'Alertas de clima severo',
                                subtitle:
                                    'Receba avisos de tempestades, granizo e vendavais',
                                value: _notif,
                                onChanged: _setNotif,
                              ),
                              Divider(height: 1, color: _line),
                              _switchTile(
                                label: 'Previsão diária',
                                subtitle:
                                    'Resumo meteorológico toda manhã às 7h',
                                value: _notif,
                                onChanged: _setNotif,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── Aparência
                        _sectionCard(
                          title: 'APARÊNCIA',
                          icon: Icons.palette_outlined,
                          child: _segmented(
                            options: const {
                              'system': '🌗  Sistema',
                              'light': '☀️  Claro',
                              'dark': '🌙  Escuro',
                            },
                            selected: _theme,
                            onChanged: _setTheme,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── Idioma
                        _sectionCard(
                          title: 'IDIOMA',
                          icon: Icons.language,
                          child: _segmented(
                            options: const {
                              'pt': '🇧🇷  Português',
                              'en': '🇺🇸  English',
                            },
                            selected: _lang,
                            onChanged: _setLang,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // ── Sobre
                        _sectionCard(
                          title: 'SOBRE',
                          icon: Icons.info_outline,
                          child: Column(
                            children: [
                              _infoTile('Versão do app', '1.0.0'),
                              Divider(height: 1, color: _line),
                              _infoTile('Dados de clima', 'Open-Meteo API'),
                              Divider(height: 1, color: _line),
                              _infoTile('Geocoding', 'Nominatim / Open-Meteo'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: const BottomNavigation(),
    );
  }

  Widget _sectionCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Icon(icon, size: 16, color: const Color(0xFF2563EB)),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _muted,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
          child,
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _segmented({
    required Map<String, String> options,
    required String selected,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: options.entries.map((e) {
          final active = selected == e.key;
          return GestureDetector(
            onTap: () => onChanged(e.key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: active
                    ? const Color(0xFF2563EB)
                    : (_isDark
                        ? const Color(0xFF0F172A)
                        : const Color(0xFFF3F4F6)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: active ? const Color(0xFF2563EB) : _line,
                ),
              ),
              child: Text(
                e.value,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: active ? Colors.white : _text,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _switchTile({
    required String label,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: _text)),
                const SizedBox(height: 2),
                Text(subtitle, style: TextStyle(fontSize: 12, color: _muted)),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeColor: const Color(0xFF2563EB),
          ),
        ],
      ),
    );
  }

  Widget _infoTile(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w500, color: _text)),
          Text(value, style: TextStyle(fontSize: 13, color: _muted)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ProfileScreen
// ─────────────────────────────────────────────

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _isEditing = false;
  bool _isSaving = false;
  bool _loadingPrefs = true;

  late Map<String, String> _userData;
  late Map<String, String> _editData;

  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _cityController = TextEditingController();

  // phone verification
  bool _phoneVerifying = false;
  bool _phoneCodeSent = false;
  String _verificationId = '';
  final _codeController = TextEditingController();

  static const _headerGradient =
      LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF06B6D4)]);
  static const _avatarGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF3B82F6), Color(0xFF22D3EE)],
  );
  static const _saveGradient =
      LinearGradient(colors: [Color(0xFF2563EB), Color(0xFF06B6D4)]);

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _pageBg =>
      _isDark ? const Color(0xFF0B1220) : const Color(0xFFEFF6FF);
  Color get _cardBg => _isDark ? const Color(0xFF111827) : Colors.white;
  Color get _muted =>
      _isDark ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280);
  Color get _text =>
      _isDark ? const Color(0xFFE5E7EB) : const Color(0xFF1F2937);
  Color get _line =>
      _isDark ? const Color(0xFF374151) : const Color(0xFFE5E7EB);

  @override
  void initState() {
    super.initState();
    _initProfile();
  }

  Future<void> _initProfile() async {
    final savedPhone = await _Prefs.getPhone();
    final savedCity = await _Prefs.getCity();
    if (!mounted) return;

    final user = FirebaseAuth.instance.currentUser;
    _userData = {
      'name': (user?.displayName?.trim().isNotEmpty ?? false)
          ? user!.displayName!.trim()
          : 'Usuario SkyCast',
      'email': user?.email ?? 'Sem email cadastrado',
      'phone': savedPhone.isNotEmpty
          ? savedPhone
          : (user?.phoneNumber ?? 'Não informado'),
      'city': savedCity.isNotEmpty ? savedCity : 'Não informado',
      'memberSince': _formatMemberSince(user?.metadata.creationTime),
    };
    _editData = Map.from(_userData);
    _syncControllers();
    setState(() => _loadingPrefs = false);
  }

  String _formatMemberSince(DateTime? date) {
    if (date == null) return 'Data indisponível';
    const months = [
      'Janeiro',
      'Fevereiro',
      'Março',
      'Abril',
      'Maio',
      'Junho',
      'Julho',
      'Agosto',
      'Setembro',
      'Outubro',
      'Novembro',
      'Dezembro',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  void _syncControllers() {
    _nameController.text = _editData['name']!;
    _emailController.text = _editData['email']!;
    _phoneController.text = _editData['phone']!;
    _cityController.text = _editData['city']!;
  }

  // ── Salvar perfil ──────────────────────────

  Future<void> _handleSave() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);

    final user = FirebaseAuth.instance.currentUser;
    final newName = _nameController.text.trim();
    final newEmail = _emailController.text.trim();
    final newPhone = _phoneController.text.trim();
    final newCity = _cityController.text.trim();

    try {
      if (user != null) {
        if (newName.isNotEmpty && newName != (user.displayName ?? ''))
          await user.updateDisplayName(newName);

        if (newEmail.isNotEmpty && user.email != null && newEmail != user.email)
          await user.updateEmail(newEmail);

        await user.reload();
      }

      // persist phone & city locally
      await _Prefs.setPhone(newPhone);
      await _Prefs.setCity(newCity);

      if (!mounted) return;
      setState(() {
        _editData = {
          ..._userData,
          'name': newName,
          'email': newEmail,
          'phone': newPhone.isNotEmpty ? newPhone : 'Não informado',
          'city': newCity.isNotEmpty ? newCity : 'Não informado',
        };
        _userData = Map.from(_editData);
        _isEditing = false;
      });
      _showMessage('Perfil atualizado com sucesso.');
    } on FirebaseAuthException catch (e) {
      _showMessage(e.code == 'requires-recent-login'
          ? 'Para alterar o email, faça login novamente.'
          : 'Erro: ${e.message ?? e.code}');
    } catch (_) {
      _showMessage('Não foi possível salvar. Tente novamente.');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Verificação de telefone ─────────────────

  Future<void> _sendPhoneCode() async {
    final phone = _phoneController.text.trim();
    if (phone.length < 8) {
      _showMessage(
          'Informe um número válido com código do país (ex: +5511...)');
      return;
    }

    setState(() => _phoneVerifying = true);

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phone,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (cred) async {
        await FirebaseAuth.instance.currentUser?.linkWithCredential(cred);
        if (mounted)
          setState(() {
            _phoneCodeSent = false;
            _phoneVerifying = false;
          });
        _showMessage('Telefone verificado automaticamente!');
      },
      verificationFailed: (e) {
        if (mounted) setState(() => _phoneVerifying = false);
        _showMessage('Falha: ${e.message ?? e.code}');
      },
      codeSent: (vId, _) {
        if (mounted)
          setState(() {
            _verificationId = vId;
            _phoneCodeSent = true;
            _phoneVerifying = false;
          });
        _showMessage('Código enviado para $phone');
      },
      codeAutoRetrievalTimeout: (_) {},
    );
  }

  Future<void> _verifyCode() async {
    final code = _codeController.text.trim();
    if (code.length != 6) {
      _showMessage('Digite o código de 6 dígitos.');
      return;
    }
    try {
      final cred = PhoneAuthProvider.credential(
        verificationId: _verificationId,
        smsCode: code,
      );
      await FirebaseAuth.instance.currentUser?.linkWithCredential(cred);
      await _Prefs.setPhone(_phoneController.text.trim());
      if (!mounted) return;
      setState(() {
        _phoneCodeSent = false;
        _verificationId = '';
      });
      _showMessage('Telefone vinculado com sucesso!');
    } on FirebaseAuthException catch (e) {
      _showMessage('Código inválido: ${e.message ?? e.code}');
    }
  }

  // ── Cancel / Logout ─────────────────────────

  void _handleCancel() {
    setState(() {
      _editData = Map.from(_userData);
      _syncControllers();
      _isEditing = false;
      _phoneCodeSent = false;
      _phoneVerifying = false;
    });
  }

  Future<void> _handleLogout(BuildContext context) async {
    await FirebaseAuth.instance.signOut();
    await GoogleSignIn().signOut();
    if (!context.mounted) return;
    context.go('/login');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _cityController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loadingPrefs) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: _pageBg,
      body: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 448),
                  child: Column(
                    children: [
                      _buildAvatarCard(),
                      const SizedBox(height: 16),
                      _buildInfoCard(),
                      const SizedBox(height: 16),
                      _buildActionsCard(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: const BottomNavigation(),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: _isDark
            ? const LinearGradient(
                colors: [Color(0xFF0F172A), Color(0xFF1E293B)])
            : _headerGradient,
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Meu Perfil',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('Gerencie suas informações pessoais',
                  style: TextStyle(color: Color(0xFFBFDBFE), fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarCard() {
    return _card(
      child: Column(
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: const BoxDecoration(
              gradient: _avatarGradient,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                    color: Color(0x403B82F6),
                    blurRadius: 16,
                    offset: Offset(0, 6)),
              ],
            ),
            child: const Icon(Icons.person, size: 48, color: Colors.white),
          ),
          const SizedBox(height: 16),
          Text(
            _userData['name']!,
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.bold, color: _text),
          ),
          const SizedBox(height: 4),
          Text(
            'Membro desde ${_userData['memberSince']}',
            style: TextStyle(color: _muted, fontSize: 13),
          ),
          if (!_isEditing) ...[
            const SizedBox(height: 20),
            _outlineButton(
              icon: Icons.edit_outlined,
              label: 'Editar Perfil',
              onTap: () => setState(() => _isEditing = true),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInfoCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Informações da Conta',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          _isEditing ? _buildEditForm() : _buildInfoList(),
        ],
      ),
    );
  }

  Widget _buildInfoList() {
    return Column(
      children: [
        _infoRow(Icons.mail_outline, 'Email', _userData['email']!,
            divider: true),
        _infoRow(Icons.phone_outlined, 'Telefone', _userData['phone']!,
            divider: true),
        _infoRow(Icons.location_on_outlined, 'Localização', _userData['city']!),
      ],
    );
  }

  Widget _infoRow(IconData icon, String label, String value,
      {bool divider = false}) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: const Color(0xFF2563EB)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(fontSize: 11, color: _muted)),
                    const SizedBox(height: 2),
                    Text(value,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: _text)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (divider) Divider(height: 1, color: _line),
      ],
    );
  }

  Widget _buildEditForm() {
    return Column(
      children: [
        _editField(
          label: 'Nome Completo',
          controller: _nameController,
          icon: Icons.person_outline,
          type: TextInputType.name,
        ),
        const SizedBox(height: 16),
        _editField(
          label: 'Email',
          controller: _emailController,
          icon: Icons.mail_outline,
          type: TextInputType.emailAddress,
        ),
        const SizedBox(height: 16),

        // ── Telefone com verificação ──────────
        _editFieldWithAction(
          label: 'Telefone (ex: +5511999999999)',
          controller: _phoneController,
          icon: Icons.phone_outlined,
          type: TextInputType.phone,
          actionLabel: _phoneVerifying
              ? '...'
              : (_phoneCodeSent ? 'Reenviar' : 'Verificar'),
          onAction: _phoneVerifying ? null : _sendPhoneCode,
        ),

        // código SMS
        if (_phoneCodeSent) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _editField(
                  label: 'Código SMS (6 dígitos)',
                  controller: _codeController,
                  icon: Icons.sms_outlined,
                  type: TextInputType.number,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 56,
                child: ElevatedButton(
                  onPressed: _verifyCode,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child:
                      const Text('OK', style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ],

        const SizedBox(height: 16),

        // ── Localização com ícone GPS ─────────
        _editFieldWithAction(
          label: 'Localização',
          controller: _cityController,
          icon: Icons.location_on_outlined,
          type: TextInputType.streetAddress,
          actionLabel: 'GPS',
          actionIcon: Icons.my_location,
          onAction: _detectarCidadeGPS,
        ),

        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
                child: _outlineButton(
                    icon: Icons.close,
                    label: 'Cancelar',
                    onTap: _handleCancel)),
            const SizedBox(width: 8),
            Expanded(child: _gradientButton()),
          ],
        ),
      ],
    );
  }

  // ── Detectar cidade via GPS ──────────────────

  Future<void> _detectarCidadeGPS() async {
    _showMessage('Obtendo localização...');
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('Ative o GPS.');

      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied)
        perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever)
        throw Exception('Permissão negada.');

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 12),
      );

      final uri = _backendUri('/api/reverse', {
        'lat': pos.latitude.toString(),
        'lon': pos.longitude.toString(),
        'lang': 'pt',
      });
      final resp = await http.get(uri).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final city = address['city'] as String? ??
              address['town'] as String? ??
              address['village'] as String? ??
              address['municipality'] as String?;
          final state = address['state'] as String?;
          if (city != null) {
            final label = state != null ? '$city, $state' : city;
            setState(() => _cityController.text = label);
            _showMessage('Localização detectada: $label');
            return;
          }
        }
      }
      throw Exception('Não foi possível determinar a cidade.');
    } catch (e) {
      _showMessage(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  // ── Widgets auxiliares ─────────────────────

  Widget _editField({
    required String label,
    required TextEditingController controller,
    required IconData icon,
    required TextInputType type,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: _muted)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          keyboardType: type,
          style: TextStyle(color: _text),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: _muted, size: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: _line),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2),
            ),
            filled: true,
            fillColor: _isDark ? const Color(0xFF0F172A) : Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          ),
        ),
      ],
    );
  }

  Widget _editFieldWithAction({
    required String label,
    required TextEditingController controller,
    required IconData icon,
    required TextInputType type,
    required String actionLabel,
    IconData? actionIcon,
    VoidCallback? onAction,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: _muted)),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: controller,
                keyboardType: type,
                style: TextStyle(color: _text),
                decoration: InputDecoration(
                  prefixIcon: Icon(icon, color: _muted, size: 20),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _line),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: Color(0xFF2563EB), width: 2),
                  ),
                  filled: true,
                  fillColor: _isDark ? const Color(0xFF0F172A) : Colors.white,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 52,
              child: OutlinedButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon ?? Icons.verified_outlined, size: 16),
                label: Text(actionLabel, style: const TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  side: const BorderSide(color: Color(0xFF2563EB)),
                  foregroundColor: const Color(0xFF2563EB),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _gradientButton() {
    return GestureDetector(
      onTap: _isSaving ? null : _handleSave,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          gradient: _saveGradient,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_isSaving)
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
            else ...[
              const Icon(Icons.check, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text('Salvar',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w600)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionsCard(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        children: [
          _actionTile(
            icon: Icons.settings_outlined,
            label: 'Configurações',
            iconColor: const Color(0xFF4B5563),
            textColor: const Color(0xFF1F2937),
            onTap: () => context.push('/settings'), // ← navega
            divider: true,
          ),
          _actionTile(
            icon: Icons.logout,
            label: 'Sair da Conta',
            iconColor: const Color(0xFFDC2626),
            textColor: const Color(0xFFDC2626),
            hoverColor: const Color(0xFFFEF2F2),
            onTap: () => _handleLogout(context),
          ),
        ],
      ),
    );
  }

  Widget _actionTile({
    required IconData icon,
    required String label,
    required Color iconColor,
    required Color textColor,
    Color hoverColor = const Color(0xFFF9FAFB),
    required VoidCallback onTap,
    bool divider = false,
  }) {
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: divider
                ? const BorderRadius.vertical(top: Radius.circular(24))
                : const BorderRadius.vertical(bottom: Radius.circular(24)),
            highlightColor: hoverColor,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: iconColor),
                  const SizedBox(width: 12),
                  Text(label,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: textColor)),
                  const Spacer(),
                  const Icon(Icons.chevron_right,
                      size: 18, color: Color(0xFF94A3B8)),
                ],
              ),
            ),
          ),
        ),
        if (divider) Divider(height: 1, color: _line),
      ],
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: child,
    );
  }

  Widget _outlineButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          side: BorderSide(color: _line),
          foregroundColor: _text,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ExploreScreen (placeholder)
// ─────────────────────────────────────────────

class ExploreScreen extends StatelessWidget {
  const ExploreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Explorar')),
      body: const Center(child: Text('Tela de explorar')),
      bottomNavigationBar: const BottomNavigation(),
    );
  }
}

// ─────────────────────────────────────────────
// GoRouterRefreshStream
// ─────────────────────────────────────────────

class GoRouterRefreshStream extends ChangeNotifier {
  GoRouterRefreshStream(Stream<dynamic> stream) {
    _subscription = stream.asBroadcastStream().listen((_) => notifyListeners());
  }

  late final StreamSubscription<dynamic> _subscription;

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

// ─────────────────────────────────────────────
// HomePage  (inalterada — colada abaixo)
// ─────────────────────────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  void _goToTrip() => context.go('/route');

  bool _loading = true;
  String? _error;
  String _locationLabel = 'Obtendo localização...';
  WeatherData? _weather;

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
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

  Future<String> _reverseGeocode(double lat, double lon) async {
    try {
      final uri = _backendUri('/api/reverse', {
        'lat': lat.toString(),
        'lon': lon.toString(),
        'lang': 'pt',
      });
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final city = address['city'] as String? ??
              address['town'] as String? ??
              address['village'] as String? ??
              address['municipality'] as String?;
          final state = address['state'] as String?;
          if (city != null) return state != null ? '$city, $state' : city;
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
          latitude: position.latitude, longitude: position.longitude);
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
    if (permission == LocationPermission.denied)
      permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied)
      throw Exception('Permissão de localização negada.');
    if (permission == LocationPermission.deniedForever)
      throw Exception('Permissão negada permanentemente.');
    return Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 15),
    );
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }
    _debounce = Timer(
        const Duration(milliseconds: 400), () => _buscarLocais(query.trim()));
  }

  Future<void> _buscarLocais(String query) async {
    setState(() => _searchLoading = true);
    try {
      final uri = _backendUri('/api/geocode', {
        'name': query,
        'count': '8',
        'lang': 'pt',
      });
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
          latitude: location.latitude, longitude: location.longitude);
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

  Future<WeatherData> _buscarClima({
    required double latitude,
    required double longitude,
  }) async {
    final uri = _backendUri('/api/weather', {
      'lat': latitude.toString(),
      'lon': longitude.toString(),
      'timezone': 'auto',
      'forecast_days': '10',
    });
    final response = await http.get(uri).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200)
      throw Exception('Não foi possível consultar o clima agora.');
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
        if (i == 0)
          label = 'Hoje';
        else if (i == 1)
          label = 'Amanhã';
        else
          label = date != null ? _dayLabels[date.weekday % 7] : '---';
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

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final weather = _weather;
    final condition = weather?.condition ?? WeatherCondition.partly;
    final gradient = dark
        ? const [Color(0xFF0B1220), Color(0xFF111827)]
        : condition.gradient;

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
                  _buildHeader(),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: _carregarPorGPS,
                      color: Colors.white,
                      backgroundColor: Colors.white.withOpacity(0.2),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: [
                          _buildSearchBar(),
                          const SizedBox(height: 16),
                          if (_loading && weather == null)
                            _buildLoadingHero()
                          else ...[
                            FadeTransition(
                                opacity: _fadeAnim,
                                child: _buildHero(weather, condition)),
                            const SizedBox(height: 16),
                            if (weather != null)
                              FadeTransition(
                                  opacity: _fadeAnim,
                                  child: _buildStatsGrid(weather)),
                            const SizedBox(height: 16),
                            if (weather != null && weather.forecast.isNotEmpty)
                              FadeTransition(
                                  opacity: _fadeAnim,
                                  child: _buildForecast(weather)),
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
          bottomNavigationBar: const BottomNavigation(),
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
                  Shadow(color: Colors.black.withOpacity(0.15), blurRadius: 8)
                ],
              ),
            ),
          ),
          _GlassButton(
            onTap: _loading ? null : _carregarPorGPS,
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
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
                              strokeWidth: 2, color: Colors.white)))
                  : _searchController.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close,
                              color: Colors.white70, size: 18),
                          onPressed: () {
                            _searchController.clear();
                            _onSearchChanged('');
                          })
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
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: dark
            ? const Color(0xFF111827).withOpacity(0.98)
            : Colors.white.withOpacity(0.95),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 16,
              offset: const Offset(0, 6)),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: _suggestions.isEmpty
            ? Padding(
                padding: EdgeInsets.all(16),
                child: Text('Nenhuma cidade encontrada.',
                    style: TextStyle(
                        color:
                            dark ? const Color(0xFF9CA3AF) : Colors.black54)))
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
                                  Text(_suggestions[i].name,
                                      style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 14,
                                          color: dark
                                              ? const Color(0xFFE5E7EB)
                                              : Colors.black87)),
                                  Text(
                                    [
                                      if (_suggestions[i].admin1 != null)
                                        _suggestions[i].admin1!,
                                      _suggestions[i].country,
                                    ].join(', '),
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: dark
                                            ? const Color(0xFF9CA3AF)
                                            : Colors.black45),
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
                    color: Colors.white, strokeWidth: 2.5)),
            SizedBox(height: 16),
            Text('Obtendo localização...',
                style: TextStyle(color: Colors.white70, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _buildHero(WeatherData? weather, WeatherCondition condition) {
    return Column(
      children: [
        const SizedBox(height: 8),
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
                    fontWeight: FontWeight.w500),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          weather != null ? '${weather.temperature.round()}°' : '--°',
          style: TextStyle(
            fontSize: 96,
            fontWeight: FontWeight.w200,
            color: Colors.white,
            height: 1.0,
            shadows: [
              Shadow(color: Colors.black.withOpacity(0.1), blurRadius: 20)
            ],
          ),
        ),
        Text(
          condition.label,
          style: const TextStyle(
              fontSize: 20,
              color: Colors.white,
              fontWeight: FontWeight.w300,
              letterSpacing: 0.5),
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
                Text(s.$3,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13)),
                const SizedBox(height: 2),
                Text(s.$2,
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55), fontSize: 10)),
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
                  letterSpacing: 1.5),
            ),
          ),
          const Divider(
              height: 1, color: Colors.white24, indent: 16, endIndent: 16),
          ...List.generate(weather.forecast.length, (i) {
            final day = weather.forecast[i];
            final isLast = i == weather.forecast.length - 1;
            return Column(
              children: [
                _ForecastRow(
                  day: day,
                  globalMin: globalMin,
                  globalMax: globalMax,
                  currentTemp: i == 0 ? weather.temperature : null,
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
            child: Text(_error!,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// ForecastRow / TempBar / GlassButton (inalterados)
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
          SizedBox(
            width: 52,
            child: Text(day.label,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                    fontSize: 14)),
          ),
          SizedBox(
            width: 44,
            child: Column(
              children: [
                Text(day.condition.emoji, style: const TextStyle(fontSize: 20)),
                if (day.precipChance >= 20)
                  Text('${day.precipChance}%',
                      style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF93c5fd),
                          fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Text('${day.min}°',
                    style: TextStyle(
                        color: Colors.white.withOpacity(0.55), fontSize: 12)),
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
                Text('${day.max}°',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
              Container(
                height: 6,
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3)),
              ),
              Positioned(
                left: leftFrac * total,
                width: (widthFrac * total).clamp(4.0, total),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                        colors: [Color(0xFF60a5fa), Color(0xFFfbbf24)]),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
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
                        BoxShadow(color: Colors.black26, blurRadius: 4)
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
