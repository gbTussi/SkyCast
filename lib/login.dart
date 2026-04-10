import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_sign_in/google_sign_in.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isRegisterMode = false;
  bool _isLoading = false;

  Future<void> _handleEmailAuth() async {
    if (!_formKey.currentState!.validate()) return;

    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final isRegistering = _isRegisterMode;

    if (_isRegisterMode && password != _confirmPasswordController.text.trim()) {
      _showMessage('As senhas nao conferem.');
      return;
    }

    setState(() => _isLoading = true);
    try {
      if (_isRegisterMode) {
        await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );
      }
      if (!mounted) return;
      _showMessage(
        isRegistering
            ? 'Conta criada com sucesso!'
            : 'Login realizado com sucesso!',
      );
      context.go('/home');
    } on FirebaseAuthException catch (e) {
      _showMessage(_firebaseErrorMessage(e));
    } catch (_) {
      _showMessage('Nao foi possivel autenticar agora. Tente novamente.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleGoogleLogin() async {
    setState(() => _isLoading = true);
    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      final googleAuth = await googleUser.authentication;
      if (googleAuth.idToken == null || googleAuth.accessToken == null) {
        throw FirebaseAuthException(
          code: 'google-token-missing',
          message: 'Google nao retornou tokens de autenticacao.',
        );
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      await FirebaseAuth.instance.signInWithCredential(credential);
      if (!mounted) return;
      context.go('/home');
    } on FirebaseAuthException catch (e) {
      debugPrint('Google/Firebase auth error: ${e.code} - ${e.message}');
      _showMessage(_firebaseErrorMessage(e));
    } on PlatformException catch (e) {
      debugPrint('Google sign-in platform error: ${e.code} - ${e.message}');
      _showMessage('Falha no login Google: ${e.code}.');
    } catch (e, st) {
      debugPrint('Google sign-in unknown error: $e');
      debugPrintStack(stackTrace: st);
      _showMessage('Falha no login com Google. Detalhes no terminal.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _firebaseErrorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-email':
        return 'Email invalido.';
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
        return 'Email ou senha invalidos.';
      case 'email-already-in-use':
        return 'Este email ja esta em uso.';
      case 'weak-password':
        return 'A senha deve ter no minimo 6 caracteres.';
      case 'network-request-failed':
        return 'Sem conexao. Verifique sua internet.';
      case 'operation-not-allowed':
        return 'Metodo de login desativado no Firebase. Ative Email/Senha.';
      case 'too-many-requests':
        return 'Muitas tentativas. Aguarde e tente novamente.';
      case 'google-token-missing':
        return 'Tokens Google ausentes. Revise a configuracao OAuth do Firebase.';
      default:
        return 'Erro de autenticacao: ${e.message ?? e.code}';
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 448),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  const _SkycastLogo(size: 200),
                  const SizedBox(height: 6),
                  const Text(
                    'Planeje sua viagem com o clima ideal',
                    style: TextStyle(color: Color(0xFF374151), fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.16),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(28),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Email',
                            style: TextStyle(
                              color: Color(0xFF374151),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: _inputDecoration(
                              hint: 'seu@email.com',
                              icon: Icons.mail_outline,
                            ),
                            validator: (v) => (v == null || v.isEmpty)
                                ? 'Informe o email'
                                : null,
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            'Senha',
                            style: TextStyle(
                              color: Color(0xFF374151),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: true,
                            decoration: _inputDecoration(
                              hint: '********',
                              icon: Icons.lock_outline,
                            ),
                            validator: (v) {
                              if (v == null || v.isEmpty)
                                return 'Informe a senha';
                              if (v.length < 6) return 'Minimo de 6 caracteres';
                              return null;
                            },
                          ),
                          if (_isRegisterMode) ...[
                            const SizedBox(height: 16),
                            const Text(
                              'Confirmar senha',
                              style: TextStyle(
                                color: Color(0xFF374151),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _confirmPasswordController,
                              obscureText: true,
                              decoration: _inputDecoration(
                                hint: '********',
                                icon: Icons.lock_person_outlined,
                              ),
                              validator: (v) {
                                if (!_isRegisterMode) return null;
                                if (v == null || v.isEmpty) {
                                  return 'Confirme sua senha';
                                }
                                if (v != _passwordController.text) {
                                  return 'As senhas nao conferem';
                                }
                                return null;
                              },
                            ),
                          ],
                          const SizedBox(height: 20),
                          SizedBox(
                            width: double.infinity,
                            height: 56,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF2563EB),
                                    Color(0xFF06B6D4)
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: ElevatedButton(
                                onPressed: _isLoading ? null : _handleEmailAuth,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: _isLoading
                                    ? const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Text(
                                        _isRegisterMode
                                            ? 'Criar conta'
                                            : 'Entrar',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white,
                                        ),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: _isLoading ? null : _handleGoogleLogin,
                            icon: const Icon(Icons.g_mobiledata, size: 28),
                            label: const Text('Continuar com Google'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(double.infinity, 52),
                              side: const BorderSide(color: Color(0xFFD1D5DB)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                _isRegisterMode
                                    ? 'Ja tem conta? '
                                    : 'Nao tem conta? ',
                                style: const TextStyle(
                                  color: Color(0xFF4B5563),
                                  fontSize: 14,
                                ),
                              ),
                              GestureDetector(
                                onTap: _isLoading
                                    ? null
                                    : () {
                                        setState(() {
                                          _isRegisterMode = !_isRegisterMode;
                                          _confirmPasswordController.clear();
                                        });
                                      },
                                child: Text(
                                  _isRegisterMode ? 'Entrar' : 'Cadastre-se',
                                  style: const TextStyle(
                                    color: Color(0xFF2563EB),
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!_isRegisterMode) ...[
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: _isLoading
                          ? null
                          : () => context.push('/reset-password'),
                      child: const Text(
                        'Esqueceu sua senha?',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(
      {required String hint, required IconData icon}) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
      prefixIcon: Icon(icon, color: const Color(0xFF9CA3AF)),
      filled: true,
      fillColor: const Color(0xFFF9FAFB),
      contentPadding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2),
      ),
    );
  }
}

class _SkycastLogo extends StatelessWidget {
  final double size;
  const _SkycastLogo({required this.size});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icon/app_icon.png',
      width: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}
