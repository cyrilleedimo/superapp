<?php
// Envoi d'e-mails (codes de vérification, mot de passe oublié, avis de commande).
//   • SMTP authentifié si Admin → Réglages contient un compte e-mail (recommandé : meilleure délivrabilité) ;
//   • sinon la fonction mail() de l'hébergeur.
// Chaque envoi laisse une trace dans mail_outbox (sans le contenu). En phase pilote,
// l'admin peut y lire les derniers codes si un e-mail tarde à arriver.
declare(strict_types=1);

namespace Ovia;

final class Mailer
{
    /** @var list<array{0:string,1:string,2:string}> avis à envoyer après la réponse HTTP */
    private static array $queue = [];

    public static function fromAddress(): string
    {
        $from = App::$settings->str('mail.from');
        if ($from !== '' && filter_var($from, FILTER_VALIDATE_EMAIL)) return $from;
        $smtpUser = App::$settings->str('smtp.user');
        if (filter_var($smtpUser, FILTER_VALIDATE_EMAIL)) return $smtpUser;
        $host = strtolower((string) parse_url(App::publicUrl(), PHP_URL_HOST));
        $labels = explode('.', $host);
        if (count($labels) > 2) array_shift($labels); // app.exemple.org → exemple.org (là où existent SPF/DKIM)
        return 'no-reply@' . (count($labels) >= 2 ? implode('.', $labels) : 'localhost.localdomain');
    }

    public static function sendCode(string $to, string $code, string $purpose): bool
    {
        $app = App::$settings->str('app.name');
        [$subject, $intro] = match ($purpose) {
            'reset_password' => ["$code : ton code pour changer de mot de passe $app", 'Tu as demandé à changer ton mot de passe. Voici ton code :'],
            default => ["$code : ton code de vérification $app", "Bienvenue sur $app ! Voici ton code de vérification :"],
        };
        $text = "$intro\n\n    $code\n\nIl expire dans 10 minutes. Ne le partage avec personne : l'équipe $app ne te le demandera jamais.\n"
            . "Si tu n'es pas à l'origine de cette demande, ignore cet e-mail.";
        $html = self::layout($app, '<p style="margin:0 0 18px">' . htmlspecialchars($intro) . '</p>'
            . '<div style="font-size:34px;letter-spacing:10px;font-weight:700;background:#EBEDFF;color:#2B3CF0;border-radius:14px;padding:18px 0;text-align:center">' . $code . '</div>'
            . '<p style="margin:18px 0 0;color:#4A5260;font-size:14px">Il expire dans 10 minutes. Ne le partage avec personne : l\'équipe ' . htmlspecialchars($app)
            . ' ne te le demandera jamais.<br>Si tu n\'es pas à l\'origine de cette demande, ignore cet e-mail.</p>');
        return self::send($to, $subject, $text, $html, $code);
    }

    /** Avis lié à une commande, un retrait… envoyé après la réponse pour ne pas ralentir l'utilisateur. */
    public static function queueNotice(string $userId, string $title, string $body): void
    {
        self::$queue[] = [$userId, $title, $body];
    }

    public static function flush(): void
    {
        $queue = self::$queue;
        self::$queue = [];
        foreach ($queue as [$userId, $title, $body]) {
            $u = App::$db->one('SELECT email, email_verified FROM users WHERE id=?', [$userId]);
            if (!$u || empty($u['email']) || !(int) $u['email_verified']) continue;
            $app = App::$settings->str('app.name');
            $html = self::layout($app, '<h2 style="margin:0 0 10px;font-size:20px">' . htmlspecialchars($title) . '</h2><p style="margin:0;color:#4A5260">'
                . nl2br(htmlspecialchars($body)) . '</p><p style="margin:18px 0 0;color:#4A5260;font-size:14px">Ouvre l\'application ' . htmlspecialchars($app) . ' pour voir le détail.</p>');
            self::send((string) $u['email'], "$title — $app", "$title\n\n$body\n\nOuvre l'application $app pour voir le détail.", $html, null);
        }
    }

    private static function layout(string $app, string $inner): string
    {
        return '<!doctype html><html lang="fr"><body style="margin:0;background:#F4F5F7;font-family:Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#0E1116">'
            . '<div style="max-width:480px;margin:0 auto;padding:28px 16px"><div style="font-size:22px;font-weight:800;color:#2B3CF0;margin-bottom:16px">' . htmlspecialchars($app) . '</div>'
            . '<div style="background:#fff;border-radius:20px;padding:26px;font-size:16px;line-height:1.5">' . $inner . '</div>'
            . '<p style="color:#8A909B;font-size:12px;text-align:center;margin:16px 0 0">Message automatique, merci de ne pas y répondre.</p></div></body></html>';
    }

    public static function send(string $to, string $subject, string $text, string $html, ?string $code): bool
    {
        $s = App::$settings;
        $from = self::fromAddress();
        $fromName = $s->str('mail.from_name') ?: $s->str('app.name');
        $boundary = 'ovia-' . bin2hex(random_bytes(8));
        $host = substr(strrchr($from, '@') ?: '@localhost', 1);
        $headers = [
            'Date' => gmdate('D, d M Y H:i:s') . ' +0000',
            'From' => self::encodeWord($fromName) . " <$from>",
            'To' => "<$to>",
            'Subject' => self::encodeWord($subject),
            'Message-ID' => '<' . bin2hex(random_bytes(12)) . "@$host>",
            'MIME-Version' => '1.0',
            'Content-Type' => "multipart/alternative; boundary=\"$boundary\"",
            'Auto-Submitted' => 'auto-generated',
        ];
        $body = "--$boundary\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" . chunk_split(base64_encode($text))
            . "--$boundary\r\nContent-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" . chunk_split(base64_encode($html))
            . "--$boundary--\r\n";
        $error = null;
        try {
            if ($s->str('smtp.host') !== '') {
                self::smtp($from, $to, $headers, $body);
            } else {
                $h = $headers;
                unset($h['To'], $h['Subject']);
                $lines = [];
                foreach ($h as $k => $v) $lines[] = "$k: $v";
                if (!function_exists('mail') || !@mail($to, $headers['Subject'], $body, implode("\r\n", $lines), '-f' . $from)) {
                    throw new \RuntimeException('la fonction mail() de l\'hébergeur a refusé l\'envoi');
                }
            }
        } catch (\Throwable $e) {
            $error = Util::clip($e->getMessage(), 250);
            error_log('Ovia e-mail : ' . $error);
        }
        try {
            App::$db->insert('mail_outbox', [
                'to_email' => $to, 'subject' => Util::clip($subject, 190),
                'code' => $s->bool('pilot.show_codes') ? $code : null,
                'status' => $error === null ? 'sent' : 'failed', 'error' => $error, 'created_at' => Util::now(),
            ]);
        } catch (\Throwable) { /* la trace est facultative */ }
        return $error === null;
    }

    private static function encodeWord(string $s): string
    {
        return preg_match('/^[\x20-\x7e]*$/', $s) && !preg_match('/[",<>]/', $s) ? $s : '=?UTF-8?B?' . base64_encode($s) . '?=';
    }

    /** Client SMTP minimal : SSL direct (465) ou STARTTLS (587), authentification LOGIN. @param array<string,string> $headers */
    private static function smtp(string $from, string $to, array $headers, string $body): void
    {
        $s = App::$settings;
        $host = $s->str('smtp.host');
        $port = $s->int('smtp.port') ?: 465;
        $secure = $s->str('smtp.secure');
        $ctx = stream_context_create(['ssl' => ['verify_peer' => true, 'verify_peer_name' => true, 'peer_name' => $host]]);
        $fp = @stream_socket_client(($secure === 'ssl' ? 'ssl://' : 'tcp://') . "$host:$port", $errno, $errstr, 12, STREAM_CLIENT_CONNECT, $ctx);
        if (!$fp) throw new \RuntimeException("connexion SMTP impossible ($errstr)");
        stream_set_timeout($fp, 15);
        $read = function () use ($fp): string {
            $out = '';
            while (($line = fgets($fp, 1024)) !== false) {
                $out .= $line;
                if (strlen($line) < 4 || $line[3] === ' ') break;
            }
            return $out;
        };
        $cmd = function (?string $line, array $ok) use ($fp, $read): string {
            if ($line !== null) fwrite($fp, $line . "\r\n");
            $resp = $read();
            if (!in_array((int) substr($resp, 0, 3), $ok, true)) throw new \RuntimeException('SMTP : ' . trim(substr($resp, 0, 160)));
            return $resp;
        };
        try {
            $me = preg_replace('/[^A-Za-z0-9.-]/', '', (string) parse_url(App::publicUrl(), PHP_URL_HOST)) ?: 'localhost';
            $cmd(null, [220]);
            $cmd("EHLO $me", [250]);
            if ($secure === 'tls') {
                $cmd('STARTTLS', [220]);
                if (!stream_socket_enable_crypto($fp, true, STREAM_CRYPTO_METHOD_TLS_CLIENT)) throw new \RuntimeException('SMTP : chiffrement TLS refusé');
                $cmd("EHLO $me", [250]);
            }
            if ($s->str('smtp.user') !== '') {
                $cmd('AUTH LOGIN', [334]);
                $cmd(base64_encode($s->str('smtp.user')), [334]);
                $cmd(base64_encode($s->str('smtp.pass')), [235]);
            }
            $cmd("MAIL FROM:<$from>", [250]);
            $cmd("RCPT TO:<$to>", [250, 251]);
            $cmd('DATA', [354]);
            $msg = '';
            foreach ($headers as $k => $v) $msg .= "$k: $v\r\n";
            $msg .= "\r\n" . $body;
            $msg = preg_replace('/^\./m', '..', $msg) ?? $msg; // « dot-stuffing »
            fwrite($fp, $msg . "\r\n.\r\n");
            $cmd(null, [250]);
            fwrite($fp, "QUIT\r\n");
        } finally {
            fclose($fp);
        }
    }
}
