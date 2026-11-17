// Connexion (e-mail ou téléphone), inscription par e-mail avec code de vérification,
// mot de passe oublié, et ajout d'un e-mail pour les comptes créés avant.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/data.dart';
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

bool _looksLikeEmail(String s) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

String _withNext(String path, String? next) =>
    next == null || next.isEmpty ? path : '$path${path.contains('?') ? '&' : '?'}next=${Uri.encodeQueryComponent(next)}';

class _AuthFrame extends StatelessWidget {
  const _AuthFrame({required this.title, required this.subtitle, required this.children, this.onBack});
  final String title, subtitle;
  final List<Widget> children;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(padding: const EdgeInsets.all(24), shrinkWrap: true, children: [
              Row(children: [
                const LumoLogo(size: 36),
                const Spacer(),
                if (onBack != null) IconButton(tooltip: 'Fermer', onPressed: onBack, icon: const Icon(Icons.close_rounded)),
              ]),
              const SizedBox(height: 28),
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
  String? info;
  Future<void> run(Future<void> Function() action) async {
    setState(() { busy = true; error = null; info = null; });
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

Widget _infoText(String? e) => e == null
    ? const SizedBox.shrink()
    : Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(e, style: const TextStyle(color: LumoColors.success, fontWeight: FontWeight.w600)));

/// Champ mot de passe avec bouton « afficher ».
class _PasswordField extends StatefulWidget {
  const _PasswordField({required this.controller, this.label = 'Mot de passe', this.helper, this.onSubmitted, this.isNew = false});
  final TextEditingController controller;
  final String label;
  final String? helper;
  final ValueChanged<String>? onSubmitted;
  final bool isNew;
  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<_PasswordField> {
  bool _hidden = true;
  @override
  Widget build(BuildContext context) => TextField(
        controller: widget.controller,
        obscureText: _hidden,
        autofillHints: [widget.isNew ? AutofillHints.newPassword : AutofillHints.password],
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: widget.helper,
          suffixIcon: IconButton(
            tooltip: _hidden ? 'Afficher' : 'Masquer',
            onPressed: () => setState(() => _hidden = !_hidden),
            icon: Icon(_hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined),
          ),
        ),
      );
}

Widget _codeField(TextEditingController c, {ValueChanged<String>? onFull}) => TextField(
      controller: c, keyboardType: TextInputType.number, maxLength: 6,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: const TextStyle(fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.w600),
      decoration: const InputDecoration(labelText: 'Code à 6 chiffres', counterText: ''),
      onChanged: (v) { if (v.length == 6) onFull?.call(v); },
    );

// ------------------------------------------------------------------ Connexion
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key, this.next});
  final String? next;
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with _Submitting<LoginScreen> {
  final _id = TextEditingController();
  final _pwd = TextEditingController();
  final _newPwd = TextEditingController();
  bool _needNew = false; // le mot de passe saisi est provisoire : il faut choisir le vrai
  @override
  void dispose() { _id.dispose(); _pwd.dispose(); _newPwd.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: _needNew ? 'Choisis ton mot de passe' : 'Bon retour',
        subtitle: _needNew
            ? 'Ton mot de passe actuel est provisoire. Choisis le tien pour ouvrir ton compte.'
            : 'Connecte-toi avec ton e-mail (ou ton numéro) et ton mot de passe.',
        onBack: () => context.go('/'),
        children: [
          TextField(
            controller: _id, keyboardType: TextInputType.emailAddress, autocorrect: false,
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            decoration: const InputDecoration(labelText: 'E-mail ou numéro de téléphone', hintText: 'toi@gmail.com'),
          ),
          const SizedBox(height: 12),
          _PasswordField(controller: _pwd, label: _needNew ? 'Mot de passe provisoire' : 'Mot de passe', onSubmitted: (_) => _submit()),
          if (_needNew) ...[
            const SizedBox(height: 12),
            _PasswordField(controller: _newPwd, label: 'Nouveau mot de passe', helper: '8 caractères minimum', isNew: true, onSubmitted: (_) => _submit()),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => context.go(_withNext('/forgot', widget.next)), child: const Text('Mot de passe oublié ?')),
          ),
          const SizedBox(height: 4),
          _errorText(error),
          FilledButton(onPressed: busy ? null : _submit, child: Text(_needNew ? 'Enregistrer et me connecter' : 'Se connecter')),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: () => context.go(_withNext('/register', widget.next)), child: const Text('Créer un compte')),
          const SizedBox(height: 12),
          TextButton(onPressed: () => context.go('/'), child: const Text('Continuer sans compte')),
        ],
      );

  void _submit() {
    final raw = _id.text.trim();
    if (raw.isEmpty || _pwd.text.isEmpty) { setState(() => error = 'Saisis ton identifiant et ton mot de passe.'); return; }
    if (_needNew && _newPwd.text.length < 8) { setState(() => error = 'Le nouveau mot de passe doit faire au moins 8 caractères.'); return; }
    final identifier = raw.contains('@') ? raw : toE164(raw);
    run(() async {
      try {
        await ref.read(sessionProvider.notifier).login(identifier, _pwd.text, newPassword: _needNew ? _newPwd.text : null);
      } on ApiException catch (e) {
        // Mot de passe provisoire accepté : on demande le vrai avant d'ouvrir la session.
        if (e.code == 'password_change_required' && mounted) {
          setState(() => _needNew = true);
          return;
        }
        // Bon mot de passe mais e-mail jamais confirmé : un code vient d'être renvoyé.
        if (e.code == 'email_not_verified' && mounted) {
          final email = (e.message != null && e.message!.contains('@')) ? e.message! : raw;
          final vt = (e.data['verifyToken'] as String?) ?? '';
          context.go(_withNext('/verify?email=${Uri.encodeQueryComponent(email)}&vt=${Uri.encodeQueryComponent(vt)}', widget.next));
          return;
        }
        rethrow;
      }
    });
  }
}

// ---------------------------------------------------------------- Inscription
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key, this.next});
  final String? next;
  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> with _Submitting<RegisterScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _pwd = TextEditingController();
  @override
  void dispose() { _name.dispose(); _email.dispose(); _phone.dispose(); _pwd.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Créer un compte',
        subtitle: 'On t\'envoie un code par e-mail pour confirmer que c\'est bien toi.',
        onBack: () => context.go('/'),
        children: [
          TextField(controller: _name, textCapitalization: TextCapitalization.words, autofillHints: const [AutofillHints.name],
              decoration: const InputDecoration(labelText: 'Prénom et nom')),
          const SizedBox(height: 12),
          TextField(controller: _email, keyboardType: TextInputType.emailAddress, autocorrect: false,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Adresse e-mail', hintText: 'toi@gmail.com')),
          const SizedBox(height: 12),
          TextField(controller: _phone, keyboardType: TextInputType.phone, autofillHints: const [AutofillHints.telephoneNumber],
              decoration: const InputDecoration(labelText: 'Téléphone (facultatif)', hintText: '6XX XX XX XX', prefixText: '+237 ',
                  helperText: 'Utile pour les livraisons et Mobile Money.')),
          const SizedBox(height: 12),
          _PasswordField(controller: _pwd, isNew: true, helper: '8 caractères minimum', onSubmitted: (_) => _submit()),
          const SizedBox(height: 20),
          _errorText(error),
          FilledButton(onPressed: busy ? null : _submit, child: const Text('Recevoir mon code')),
          const SizedBox(height: 12),
          TextButton(onPressed: () => context.go(_withNext('/login', widget.next)), child: const Text('J\'ai déjà un compte')),
        ],
      );

  void _submit() {
    final email = _email.text.trim().toLowerCase();
    if (_name.text.trim().length < 2) { setState(() => error = 'Indique ton prénom et ton nom.'); return; }
    if (!_looksLikeEmail(email)) { setState(() => error = 'Cette adresse e-mail ne semble pas valide.'); return; }
    if (_pwd.text.length < 8) { setState(() => error = 'Le mot de passe doit faire au moins 8 caractères.'); return; }
    final phoneDigits = _phone.text.replaceAll(RegExp(r'\D'), '');
    run(() async {
      final vt = await ref.read(sessionProvider.notifier).register(
          name: _name.text.trim(), email: email, password: _pwd.text, phone: phoneDigits.isEmpty ? null : toE164(_phone.text));
      if (mounted) context.go(_withNext('/verify?email=${Uri.encodeQueryComponent(email)}&vt=${Uri.encodeQueryComponent(vt)}', widget.next));
    });
  }
}

// ----------------------------------------------------- Vérification de l'e-mail
class VerifyScreen extends ConsumerStatefulWidget {
  const VerifyScreen({super.key, required this.email, required this.verifyToken, this.next});
  final String email;

  /// Jeton reçu à l'inscription : sans lui, le code ne peut pas être validé depuis un autre appareil.
  final String verifyToken;
  final String? next;
  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> with _Submitting<VerifyScreen> {
  final _code = TextEditingController();
  @override
  void dispose() { _code.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Vérifie ton e-mail',
        subtitle: 'Saisis le code à 6 chiffres envoyé à ${widget.email}. Pense à regarder dans les courriers indésirables.',
        onBack: () => context.go('/login'),
        children: [
          if (widget.verifyToken.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('Cette page a été ouverte hors de l\'inscription. Reviens à la connexion et saisis ton mot de passe : un nouveau code te sera envoyé.',
                  style: TextStyle(color: LumoColors.warning, fontWeight: FontWeight.w600)),
            ),
          _codeField(_code, onFull: (_) => _submit()),
          const SizedBox(height: 20),
          _errorText(error),
          _infoText(info),
          FilledButton(onPressed: busy ? null : _submit, child: const Text('Vérifier')),
          const SizedBox(height: 12),
          TextButton(onPressed: busy ? null : _resend, child: const Text('Renvoyer le code')),
        ],
      );

  void _submit() {
    if (_code.text.length != 6 || busy) return;
    run(() => ref.read(sessionProvider.notifier).verify(widget.email, _code.text, widget.verifyToken));
  }

  void _resend() => run(() async {
        await ref.read(sessionProvider.notifier).resendCode(widget.email, widget.verifyToken);
        if (mounted) setState(() => info = 'Nouveau code envoyé.');
      });
}

// --------------------------------------------------------- Mot de passe oublié
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key, this.next});
  final String? next;
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> with _Submitting<ForgotPasswordScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _pwd = TextEditingController();
  bool _codeSent = false;
  @override
  void dispose() { _email.dispose(); _code.dispose(); _pwd.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Mot de passe oublié',
        subtitle: _codeSent
            ? 'Si un compte existe avec ${_email.text.trim()}, un code vient d\'y être envoyé. Saisis-le et choisis un nouveau mot de passe.'
            : 'Indique l\'e-mail de ton compte : on t\'envoie un code pour choisir un nouveau mot de passe.',
        onBack: () => context.go(_withNext('/login', widget.next)),
        children: [
          if (!_codeSent) ...[
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, autocorrect: false,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Adresse e-mail'), onSubmitted: (_) => _send()),
            const SizedBox(height: 20),
            _errorText(error),
            FilledButton(onPressed: busy ? null : _send, child: const Text('Recevoir le code')),
          ] else ...[
            _codeField(_code),
            const SizedBox(height: 12),
            _PasswordField(controller: _pwd, isNew: true, label: 'Nouveau mot de passe', helper: '8 caractères minimum', onSubmitted: (_) => _reset()),
            const SizedBox(height: 20),
            _errorText(error),
            FilledButton(onPressed: busy ? null : _reset, child: const Text('Changer mon mot de passe')),
            const SizedBox(height: 12),
            TextButton(onPressed: busy ? null : () => setState(() { _codeSent = false; error = null; }), child: const Text('Utiliser une autre adresse')),
          ],
        ],
      );

  void _send() {
    final email = _email.text.trim().toLowerCase();
    if (!_looksLikeEmail(email)) { setState(() => error = 'Cette adresse e-mail ne semble pas valide.'); return; }
    run(() async {
      await ref.read(sessionProvider.notifier).forgotPassword(email);
      if (mounted) setState(() => _codeSent = true);
    });
  }

  void _reset() {
    if (_code.text.length != 6) { setState(() => error = 'Saisis le code à 6 chiffres reçu par e-mail.'); return; }
    if (_pwd.text.length < 8) { setState(() => error = 'Le mot de passe doit faire au moins 8 caractères.'); return; }
    run(() => ref.read(sessionProvider.notifier).resetPassword(_email.text.trim().toLowerCase(), _code.text, _pwd.text));
  }
}

// ------------------------------------- Ajouter son e-mail (comptes créés avant)
class AddEmailScreen extends ConsumerStatefulWidget {
  const AddEmailScreen({super.key});
  @override
  ConsumerState<AddEmailScreen> createState() => _AddEmailScreenState();
}

class _AddEmailScreenState extends ConsumerState<AddEmailScreen> with _Submitting<AddEmailScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  @override
  void dispose() { _email.dispose(); _code.dispose(); super.dispose(); }

  void _close() => context.canPop() ? context.pop() : context.go('/');

  @override
  Widget build(BuildContext context) => _AuthFrame(
        title: 'Ajoute ton e-mail',
        subtitle: _codeSent
            ? 'Saisis le code à 6 chiffres envoyé à ${_email.text.trim()}.'
            : 'Ton e-mail sert à récupérer ton compte si tu oublies ton mot de passe, et à recevoir tes confirmations de commande.',
        onBack: _close,
        children: [
          if (!_codeSent) ...[
            TextField(controller: _email, keyboardType: TextInputType.emailAddress, autocorrect: false,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Adresse e-mail', hintText: 'toi@gmail.com'), onSubmitted: (_) => _send()),
            const SizedBox(height: 20),
            _errorText(error),
            FilledButton(onPressed: busy ? null : _send, child: const Text('Recevoir le code')),
          ] else ...[
            _codeField(_code, onFull: (_) => _verify()),
            const SizedBox(height: 20),
            _errorText(error),
            FilledButton(onPressed: busy ? null : _verify, child: const Text('Confirmer mon e-mail')),
            const SizedBox(height: 12),
            TextButton(onPressed: busy ? null : () => setState(() { _codeSent = false; error = null; }), child: const Text('Corriger l\'adresse')),
          ],
        ],
      );

  void _send() {
    final email = _email.text.trim().toLowerCase();
    if (!_looksLikeEmail(email)) { setState(() => error = 'Cette adresse e-mail ne semble pas valide.'); return; }
    run(() async {
      await ref.read(apiClientProvider).post('/me/email', body: {'email': email});
      if (mounted) setState(() => _codeSent = true);
    });
  }

  void _verify() {
    if (_code.text.length != 6 || busy) return;
    run(() async {
      await ref.read(apiClientProvider).post('/me/email/verify', body: {'code': _code.text});
      ref.invalidate(jsonProvider('/me'));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('E-mail confirmé. Ton compte est sécurisé.')));
        _close();
      }
    });
  }
}
