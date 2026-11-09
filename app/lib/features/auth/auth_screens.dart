// Connexion, inscription et vérification du numéro par code SMS.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/config.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../widgets/common.dart';

/// Normalise un numéro saisi localement vers E.164 (+237 par défaut : [TARGET COUNTRY]).
String toE164(String input, {String defaultCountryCode = '237'}) {
  final digits = input.replaceAll(RegExp(r'[^\d+]'), '');
  if (digits.startsWith('+')) return digits;
  if (digits.startsWith('00')) return '+${digits.substring(2)}';
  return '+$defaultCountryCode$digits';
}

class _AuthFrame extends StatelessWidget {
  const _AuthFrame({required this.title, required this.subtitle, required this.children});
  final String title, subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
              const LumoLogo(size: 36),
              const SizedBox(height: 32),
              Text(title, style: t.headlineMedium),
              const SizedBox(height: 8),
              Text(subtitle, style: t.bodyLarge?.copyWith(color: LumoColors.slate)),
              const SizedBox(height: 28),
              ...children,
            ]),
          ),
        ),
      ),
    );
  }
}

mixin _Submitting<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool busy = false;
  String? error;
  Future<void> run(Future<void> Function() action) async {
    setState(() { busy = true; error = null; });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => error = e.userMessage);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

Widget _errorText(String? e) => e == null
    ? const SizedBox.shrink()
    : Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(e, style: const TextStyle(color: LumoColors.danger, fontWeight: FontWeight.w600)));

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with _Submitting<LoginScreen> {
  final _phone = TextEditingController();
  final _pwd = TextEditingController();
  @override
  void dispose() { _phone.dispose(); _pwd.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Bon retour',
        subtitle: 'Connecte-toi avec ton numéro de téléphone.',
        children: [
          TextField(
            controller: _phone, keyboardType: TextInputType.phone, autofillHints: const [AutofillHints.telephoneNumber],
            decoration: const InputDecoration(labelText: 'Numéro de téléphone', hintText: '6XX XX XX XX', prefixText: '+237 '),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwd, obscureText: true, autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(labelText: 'Mot de passe'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 20),
          _errorText(error),
          FilledButton(onPressed: busy ? null : _submit, child: const Text('Se connecter')),
          const SizedBox(height: 12),
          TextButton(onPressed: () => context.go('/register'), child: const Text('Créer un compte')),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: _editServer,
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: Text(AppConfig.isConfigured ? 'Serveur : ${AppConfig.apiUrl}' : 'Serveur : à configurer',
                style: const TextStyle(fontSize: 12, color: LumoColors.slate)),
          ),
        ],
      );

  void _submit() => run(() => ref.read(sessionProvider.notifier).login(toE164(_phone.text), _pwd.text));

  Future<void> _editServer() async {
    final c = TextEditingController(text: AppConfig.apiUrl.isEmpty ? 'https://' : AppConfig.apiUrl);
    final url = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Adresse du serveur'),
        content: TextField(controller: c, keyboardType: TextInputType.url, decoration: const InputDecoration(hintText: 'https://api.exemple.com')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Fermer')),
          TextButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Enregistrer')),
        ],
      ),
    );
    c.dispose();
    if (url == null) return;
    final err = await AppConfig.setServer(url);
    if (mounted) setState(() => error = err);
  }
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> with _Submitting<RegisterScreen> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _pwd = TextEditingController();
  @override
  void dispose() { _name.dispose(); _phone.dispose(); _pwd.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Créer un compte',
        subtitle: 'On t\'envoie un code par SMS pour vérifier ton numéro.',
        children: [
          TextField(controller: _name, textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Prénom et nom')),
          const SizedBox(height: 12),
          TextField(controller: _phone, keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Numéro de téléphone', hintText: '6XX XX XX XX', prefixText: '+237 ')),
          const SizedBox(height: 12),
          TextField(controller: _pwd, obscureText: true, autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: 'Mot de passe', helperText: '10 caractères minimum')),
          const SizedBox(height: 20),
          _errorText(error),
          FilledButton(onPressed: busy ? null : _submit, child: const Text('Recevoir le code')),
          const SizedBox(height: 12),
          TextButton(onPressed: () => context.go('/login'), child: const Text('J\'ai déjà un compte')),
        ],
      );

  void _submit() {
    if (_pwd.text.length < 10) { setState(() => error = 'Le mot de passe doit faire au moins 10 caractères.'); return; }
    final phone = toE164(_phone.text);
    run(() async {
      await ref.read(sessionProvider.notifier).register(phone, _name.text.trim(), _pwd.text);
      if (mounted) context.go('/verify?phone=${Uri.encodeQueryComponent(phone)}');
    });
  }
}

class VerifyScreen extends ConsumerStatefulWidget {
  const VerifyScreen({super.key, required this.phone});
  final String phone;
  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> with _Submitting<VerifyScreen> {
  final _code = TextEditingController();
  @override
  void dispose() { _code.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Vérifie ton numéro',
        subtitle: 'Saisis le code à 6 chiffres envoyé au ${widget.phone}.',
        children: [
          TextField(
            controller: _code, keyboardType: TextInputType.number, maxLength: 6,
            autofillHints: const [AutofillHints.oneTimeCode],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.w600),
            decoration: const InputDecoration(labelText: 'Code', counterText: ''),
            onChanged: (v) { if (v.length == 6) _submit(); },
          ),
          const SizedBox(height: 20),
          _errorText(error),
          FilledButton(onPressed: busy ? null : _submit, child: const Text('Vérifier')),
        ],
      );

  void _submit() => run(() => ref.read(sessionProvider.notifier).verify(widget.phone, _code.text));
}
