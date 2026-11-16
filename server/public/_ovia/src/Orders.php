<?php
// Grand livre, prestataires de paiement et commandes avec séquestre (seconde main,
// covoiturage, repas, boutiques).
//
//   pending_payment ──paiement en ligne confirmé──▶ paid ──confirmation acheteur──▶ completed
//        │                                           └──litige──▶ disputed ──admin──▶ refunded | completed
//        ├──« payer à la remise »──▶ cash_due ──confirmation acheteur──▶ completed   (sans séquestre ni frais)
//        └──annulation / expiration──▶ cancelled
declare(strict_types=1);

namespace Ovia;

/** Grand livre en partie double : chaque écriture est équilibrée, le livre est en ajout seul. */
final class Ledger
{
    public static function wallet(string $userId): string { return "wallet:$userId"; }

    private static function accountId(Db $db, string $code): string
    {
        $r = $db->one('SELECT id FROM ledger_accounts WHERE code=?', [$code]);
        if ($r) return (string) $r['id'];
        if (!str_starts_with($code, 'wallet:')) throw new \RuntimeException("compte de grand livre inconnu : $code");
        $db->insertIgnore('ledger_accounts', ['id' => Util::uuid(), 'code' => $code, 'kind' => 'liability', 'created_at' => Util::now()]);
        return (string) $db->val('SELECT id FROM ledger_accounts WHERE code=?', [$code]);
    }

    /**
     * Écrit une transaction équilibrée (montant > 0 = débit, < 0 = crédit). À appeler DANS une transaction.
     * @param list<array{0:string,1:int}> $lines [compte, montant]
     */
    public static function post(Db $db, string $memo, ?string $orderId, array $lines): string
    {
        $sum = 0;
        foreach ($lines as [$account, $amount]) {
            if (!is_int($amount) || $amount === 0) throw new \RuntimeException('montant invalide');
            $sum += $amount;
        }
        if ($sum !== 0) throw new \RuntimeException("écriture déséquilibrée ($sum)");
        $txn = Util::uuid();
        foreach ($lines as [$account, $amount]) {
            $db->insert('ledger_entries', [
                'txn_id' => $txn, 'account_id' => self::accountId($db, $account), 'amount_xaf' => $amount,
                'order_id' => $orderId, 'memo' => Util::clip($memo, 190), 'created_at' => Util::now(),
            ]);
        }
        return $txn;
    }

    /** Solde signé d'un compte (débits positifs, crédits négatifs). */
    public static function balance(Db $db, string $code): int
    {
        return (int) $db->val('SELECT coalesce(sum(e.amount_xaf),0) FROM ledger_entries e JOIN ledger_accounts a ON a.id = e.account_id WHERE a.code=?', [$code]);
    }
}

// ------------------------------------------------------------------ Paiements
interface PaymentProvider
{
    public function name(): string;
    /** Crée la session de paiement. @param array{reference:string, amountXaf:int, description:string, name:string, phone:?string, email:?string, callbackUrl:string} $i
     *  @return array{providerReference:string, checkoutUrl:string} */
    public function initialize(array $i): array;
    /** Demande de paiement envoyée directement sur le téléphone (Mobile Money). @return array{status:string} */
    public function chargeMobile(string $providerReference, string $phone): array;
    /** Source de vérité, serveur à serveur. @return array{status:string, amountXaf:int, currency:string, raw:mixed} */
    public function retrieve(string $providerReference): array;
    public function verifyWebhook(string $rawBody, Req $r): bool;
}

/**
 * Notch Pay — https://developer.notchpay.co
 * L'en-tête Authorization porte la clé PUBLIQUE (pk_…). La clé privée ne sert qu'aux virements
 * sortants, que ce serveur ne fait pas : elle n'est donc jamais demandée ni stockée.
 */
final class NotchPay implements PaymentProvider
{
    private const BASE = 'https://api.notchpay.co';

    public function __construct(private string $publicKey, private string $webhookHash) {}

    public function name(): string { return 'notchpay'; }

    /** @return array<string,mixed> */
    private function call(string $method, string $path, ?array $payload = null): array
    {
        $r = Http::json($method, self::BASE . $path, ['Authorization' => $this->publicKey], $payload, 25);
        if ($r['status'] < 200 || $r['status'] >= 300) {
            throw new \RuntimeException("notchpay $path -> HTTP {$r['status']}: " . (string) ($r['json']['message'] ?? ''));
        }
        return $r['json'];
    }

    public function initialize(array $i): array
    {
        $customer = array_filter(['name' => $i['name'], 'phone' => $i['phone'], 'email' => $i['email']], fn ($v) => $v !== null && $v !== '');
        $j = $this->call('POST', '/payments', [
            'amount' => $i['amountXaf'], 'currency' => 'XAF', 'reference' => $i['reference'],
            'description' => $i['description'], 'callback' => $i['callbackUrl'], 'customer' => $customer,
        ]);
        $ref = $j['transaction']['reference'] ?? null;
        $url = $j['authorization_url'] ?? null;
        if (!is_string($ref) || !is_string($url) || !str_starts_with($url, 'https://')) throw new \RuntimeException('notchpay : réponse d\'initialisation inattendue');
        return ['providerReference' => $ref, 'checkoutUrl' => $url];
    }

    public function chargeMobile(string $providerReference, string $phone): array
    {
        // cm.mobile : le prestataire reconnaît lui-même Orange ou MTN d'après le numéro.
        $j = $this->call('POST', '/payments/' . rawurlencode($providerReference), ['channel' => 'cm.mobile', 'data' => ['phone' => $phone]]);
        return ['status' => (string) ($j['transaction']['status'] ?? 'processing')];
    }

    public function retrieve(string $providerReference): array
    {
        $j = $this->call('GET', '/payments/' . rawurlencode($providerReference));
        $t = is_array($j['transaction'] ?? null) ? $j['transaction'] : [];
        $s = strtolower((string) ($t['status'] ?? ''));
        $status = $s === 'complete' ? 'succeeded' : (in_array($s, ['failed', 'canceled', 'cancelled', 'expired', 'rejected', 'abandoned'], true) ? 'failed' : 'pending');
        return ['status' => $status, 'amountXaf' => (int) ($t['amount'] ?? 0), 'currency' => (string) ($t['currency'] ?? ''), 'raw' => $j];
    }

    public function verifyWebhook(string $rawBody, Req $r): bool
    {
        $sig = $r->header('X-Notch-Signature') ?? '';
        return $this->webhookHash !== '' && preg_match('/^[0-9a-f]{64}$/i', $sig)
            && hash_equals(hash_hmac('sha256', $rawBody, $this->webhookHash), strtolower($sig));
    }
}

/** Faux prestataire pour les tests automatisés. Activable uniquement par config.php ('allow_sandbox' => true). */
final class SandboxPay implements PaymentProvider
{
    private string $file;

    public function __construct(private string $secret)
    {
        $this->file = App::$dataDir . '/sandbox-payments.json';
    }

    public function name(): string { return 'sandbox'; }

    /** @return array<string, array{status:string, amountXaf:int}> */
    private function load(): array
    {
        $j = json_decode((string) @file_get_contents($this->file), true);
        return is_array($j) ? $j : [];
    }

    public function initialize(array $i): array
    {
        $all = $this->load();
        $ref = 'sbx_' . Util::token(12);
        $all[$ref] = ['status' => 'pending', 'amountXaf' => $i['amountXaf']];
        file_put_contents($this->file, json_encode($all), LOCK_EX);
        return ['providerReference' => $ref, 'checkoutUrl' => "https://sandbox.invalid/checkout/$ref"];
    }

    public function chargeMobile(string $providerReference, string $phone): array { return ['status' => 'processing']; }

    public function retrieve(string $providerReference): array
    {
        $s = $this->load()[$providerReference] ?? null;
        if (!$s) throw new \RuntimeException('sandbox : référence inconnue');
        return ['status' => $s['status'], 'amountXaf' => (int) $s['amountXaf'], 'currency' => 'XAF', 'raw' => $s];
    }

    public function verifyWebhook(string $rawBody, Req $r): bool
    {
        return hash_equals(hash_hmac('sha256', $rawBody, $this->secret), strtolower($r->header('X-Sandbox-Signature') ?? ''));
    }
}

final class Payments
{
    public static function provider(): ?PaymentProvider
    {
        $s = App::$settings;
        $name = $s->str('payments.provider');
        if ($name === 'notchpay' && $s->str('notchpay.public_key') !== '') {
            return new NotchPay($s->str('notchpay.public_key'), $s->str('notchpay.webhook_hash'));
        }
        if ($name === 'sandbox' && !empty(App::$config['allow_sandbox'])) return new SandboxPay((string) App::$config['data_key']);
        return null;
    }

    /** Références présentes dans un webhook (servent seulement à retrouver le paiement). @return list<string> */
    public static function refsFromWebhook(mixed $body, int $depth = 0): array
    {
        if (!is_array($body) || $depth > 3) return [];
        $out = [];
        foreach ($body as $k => $v) {
            if (is_string($v) && is_string($k) && preg_match('/reference|trxref/i', $k) && strlen($v) <= 120) $out[] = $v;
            elseif (is_array($v)) $out = array_merge($out, self::refsFromWebhook($v, $depth + 1));
        }
        return array_values(array_unique($out));
    }
}

// ------------------------------------------------------------------ Commandes
final class Orders
{
    private const KIND_LABEL = ['listing' => 'article', 'carpool' => 'réservation de trajet', 'food' => 'commande repas', 'shop' => 'commande boutique'];
    public const STEPS = ['accepted', 'preparing', 'ready', 'delivering', 'delivered'];

    public static function buyerFee(int $priceXaf): int
    {
        // Arrondi au franc supérieur : la plateforme n'encaisse jamais une fraction.
        return (int) ceil($priceXaf * App::$settings->int('fees.buyer_bps') / 10000) + App::$settings->int('fees.buyer_fixed_xaf');
    }

    /** @param array<string,mixed> $o */
    public static function view(array $o): array
    {
        return [
            'id' => $o['id'], 'kind' => $o['kind'], 'listingId' => $o['listing_id'], 'refId' => $o['ref_id'],
            'items' => json_decode((string) $o['items'], true) ?: [], 'buyerId' => $o['buyer_id'], 'sellerId' => $o['seller_id'],
            'fulfillment' => $o['fulfillment'], 'paymentMethod' => $o['payment_method'],
            'itemPriceXaf' => (int) $o['item_price_xaf'], 'buyerFeeXaf' => (int) $o['buyer_fee_xaf'], 'totalXaf' => (int) $o['total_xaf'],
            'status' => $o['status'], 'createdAt' => Util::iso((string) $o['created_at']),
        ];
    }

    /** @return array<string,mixed> */
    public static function lock(Db $db, string $id): array
    {
        $o = $db->one('SELECT * FROM orders WHERE id=?' . $db->lock(), [$id]);
        if (!$o) throw AppError::notFound();
        return $o;
    }

    /** @return array<string,mixed>|null */
    public static function findReplay(string $buyerId, string $key): ?array
    {
        return App::$db->one('SELECT * FROM orders WHERE buyer_id=? AND idempotency_key=?', [$buyerId, $key]);
    }

    /**
     * Insère une commande (dans la transaction qui a réservé l'article, les places ou le stock).
     * @param array{buyerId:string, sellerId:string, kind:string, listingId?:?string, refId?:?string, items:list<array<string,mixed>>, itemPriceXaf:int, idempotencyKey:string, offerId?:?string} $o
     * @return array<string,mixed>
     */
    public static function insert(Db $db, array $o): array
    {
        if ($o['buyerId'] === $o['sellerId']) throw AppError::forbidden('cannot_buy_from_yourself');
        $fee = self::buyerFee($o['itemPriceXaf']);
        $id = Util::uuid();
        $db->insert('orders', [
            'id' => $id, 'buyer_id' => $o['buyerId'], 'seller_id' => $o['sellerId'], 'listing_id' => $o['listingId'] ?? null,
            'kind' => $o['kind'], 'ref_id' => $o['refId'] ?? null, 'items' => (string) json_encode($o['items'], JSON_UNESCAPED_UNICODE),
            'fulfillment' => null, 'offer_id' => $o['offerId'] ?? null, 'payment_method' => 'online',
            'item_price_xaf' => $o['itemPriceXaf'], 'buyer_fee_xaf' => $fee, 'total_xaf' => $o['itemPriceXaf'] + $fee,
            'status' => 'pending_payment', 'idempotency_key' => $o['idempotencyKey'], 'paid_at' => null, 'completed_at' => null,
            'created_at' => Util::now(), 'updated_at' => Util::now(),
        ]);
        App::audit($o['buyerId'], 'order.create', 'order', $id, ['kind' => $o['kind']]);
        return (array) $db->one('SELECT * FROM orders WHERE id=?', [$id]);
    }

    /** Rend disponible ce que la commande avait réservé (article, places, stock). @param array<string,mixed> $o */
    private static function releaseReservation(Db $db, array $o): void
    {
        $items = json_decode((string) $o['items'], true) ?: [];
        if ($o['kind'] === 'listing' && $o['listing_id']) {
            $db->run("UPDATE listings SET status='active', updated_at=? WHERE id=? AND status='reserved'", [Util::now(), $o['listing_id']]);
            if ($o['offer_id']) $db->run("UPDATE offers SET status='accepted' WHERE id=? AND status='used'", [$o['offer_id']]);
        } elseif ($o['kind'] === 'carpool' && $o['ref_id']) {
            $seats = array_sum(array_map(fn ($i) => (int) ($i['qty'] ?? 0), $items));
            $db->run('UPDATE trips SET seats_left = CASE WHEN seats_left + ? > seats_total THEN seats_total ELSE seats_left + ? END WHERE id=?', [$seats, $seats, $o['ref_id']]);
        } elseif ($o['kind'] === 'shop') {
            foreach ($items as $it) {
                if (!empty($it['productId'])) $db->run('UPDATE products SET stock = stock + ? WHERE id=? AND stock IS NOT NULL', [(int) $it['qty'], $it['productId']]);
            }
        }
    }

    /** Clôt une commande : libère le séquestre vers le vendeur (paiement en ligne) ou la marque simplement terminée (remise en main propre). @param array<string,mixed> $o */
    private static function complete(Db $db, array $o, ?string $actorId, string $reason): void
    {
        $price = (int) $o['item_price_xaf'];
        $fee = (int) $o['buyer_fee_xaf'];
        if ($o['status'] !== 'cash_due') {
            $lines = [['escrow', (int) $o['total_xaf']], [Ledger::wallet((string) $o['seller_id']), -$price]];
            if ($fee > 0) $lines[] = ['platform:revenue', -$fee];
            Ledger::post($db, "libération du séquestre ($reason)", (string) $o['id'], $lines);
        }
        $db->run("UPDATE orders SET status='completed', completed_at=?, updated_at=? WHERE id=?", [Util::now(), Util::now(), $o['id']]);
        if ($o['kind'] === 'listing' && $o['listing_id']) {
            $db->run("UPDATE listings SET status='sold', updated_at=? WHERE id=?", [Util::now(), $o['listing_id']]);
        }
        App::audit($actorId, 'order.completed', 'order', (string) $o['id'], ['reason' => $reason]);
        if ($o['status'] === 'cash_due') {
            App::notify((string) $o['seller_id'], 'Commande terminée', 'L\'acheteur a confirmé avoir reçu sa commande.', "/orders/{$o['id']}");
        } else {
            App::notify((string) $o['seller_id'], 'Paiement libéré', "$price FCFA ont été ajoutés à ton porte-monnaie.", "/orders/{$o['id']}", true);
        }
    }

    /** @param array<string,mixed> $o */
    private static function cancelLocked(Db $db, array $o, ?string $actorId, string $reason): void
    {
        $db->run("UPDATE orders SET status='cancelled', updated_at=? WHERE id=?", [Util::now(), $o['id']]);
        self::releaseReservation($db, $o);
        App::audit($actorId, 'order.cancelled', 'order', (string) $o['id'], ['reason' => $reason]);
    }

    /** Applique l'état réel du prestataire à un paiement. Idempotent. */
    public static function syncPayment(string $paymentId): string
    {
        $db = App::$db;
        $p0 = $db->one('SELECT provider_reference, provider FROM payments WHERE id=?', [$paymentId]);
        $provider = Payments::provider();
        if (!$p0 || !$p0['provider_reference']) return 'initiated';
        if (!$provider || $provider->name() !== $p0['provider']) throw new AppError(503, 'payments_not_configured');
        try {
            $remote = $provider->retrieve((string) $p0['provider_reference']); // vérité serveur à serveur
        } catch (\Throwable $e) {
            throw new AppError(502, 'payment_provider_unavailable', $e->getMessage());
        }

        return $db->tx(function (Db $db) use ($paymentId, $remote): string {
            $p = (array) $db->one('SELECT id, order_id, amount_xaf, status FROM payments WHERE id=?' . $db->lock(), [$paymentId]);
            if (in_array($p['status'], ['succeeded', 'failed', 'mismatch', 'refunded'], true)) return (string) $p['status']; // déjà traité
            $order = self::lock($db, (string) $p['order_id']);
            $raw = Util::clip((string) json_encode($remote['raw'], JSON_UNESCAPED_UNICODE), 20000);
            $set = fn (string $status) => $db->run('UPDATE payments SET status=?, last_provider_data=?, updated_at=? WHERE id=?', [$status, $raw, Util::now(), $p['id']]);

            if ($remote['status'] === 'pending') { $set('pending'); return 'pending'; }
            if ($remote['status'] === 'failed') { $set('failed'); return 'failed'; }
            // Succès annoncé : on exige montant ET devise identiques à ce qui a été facturé.
            if ($remote['amountXaf'] !== (int) $p['amount_xaf'] || strtoupper($remote['currency']) !== 'XAF') {
                $set('mismatch');
                App::audit(null, 'payment.mismatch', 'payment', (string) $p['id'], ['expected' => (int) $p['amount_xaf'], 'got' => $remote['amountXaf'], 'currency' => $remote['currency']]);
                return 'mismatch';
            }
            $set('succeeded');
            Ledger::post($db, 'paiement reçu en séquestre', (string) $order['id'], [['psp:clearing', (int) $p['amount_xaf']], ['escrow', -(int) $p['amount_xaf']]]);
            if ($order['status'] === 'pending_payment') {
                $db->run("UPDATE orders SET status='paid', payment_method='online', paid_at=?, updated_at=? WHERE id=?", [Util::now(), Util::now(), $order['id']]);
                App::notify((string) $order['seller_id'], 'Nouvelle commande payée',
                    'Une ' . self::KIND_LABEL[$order['kind']] . ' vient d\'être payée. L\'argent est en séquestre.', "/orders/{$order['id']}", true);
                App::notify((string) $order['buyer_id'], 'Paiement confirmé', 'Ton argent est bloqué en sécurité jusqu\'à ta confirmation de réception.', "/orders/{$order['id']}", true);
            } else {
                // Payé après annulation : l'argent est tracé en séquestre, remboursement par un admin requis.
                App::audit(null, 'payment.after_cancel', 'order', (string) $order['id']);
            }
            App::audit(null, 'payment.succeeded', 'payment', (string) $p['id'], ['orderId' => $order['id']]);
            return 'succeeded';
        });
    }

    /**
     * Ouvre (ou réutilise) une session de paiement chez le prestataire.
     * @return array{id:string, reference:string, providerReference:string, checkoutUrl:string}
     */
    private static function openPayment(string $buyerId, string $orderId): array
    {
        $db = App::$db;
        $provider = Payments::provider();
        if (!$provider) throw new AppError(503, 'payments_not_configured');
        $order = $db->one('SELECT o.*, u.phone, u.display_name, u.email FROM orders o JOIN users u ON u.id = o.buyer_id WHERE o.id=?', [$orderId]);
        if (!$order || $order['buyer_id'] !== $buyerId) throw AppError::notFound();
        if ($order['status'] !== 'pending_payment') throw AppError::conflict('order_not_payable');

        // Réutilise une session encore ouverte plutôt que d'en créer une nouvelle.
        $open = $db->one("SELECT id, our_reference, provider_reference, checkout_url FROM payments
                          WHERE order_id=? AND provider=? AND status='pending' AND checkout_url IS NOT NULL AND created_at > ?
                          ORDER BY created_at DESC LIMIT 1", [$orderId, $provider->name(), Util::now(-1800)]);
        if ($open) {
            return ['id' => (string) $open['id'], 'reference' => (string) $open['our_reference'],
                    'providerReference' => (string) $open['provider_reference'], 'checkoutUrl' => (string) $open['checkout_url']];
        }
        $ourRef = 'ord_' . substr($orderId, 0, 8) . '_' . Util::token(9);
        $paymentId = Util::uuid();
        $db->insert('payments', [
            'id' => $paymentId, 'order_id' => $orderId, 'provider' => $provider->name(), 'our_reference' => $ourRef,
            'provider_reference' => null, 'amount_xaf' => (int) $order['total_xaf'], 'currency' => 'XAF', 'status' => 'initiated',
            'checkout_url' => null, 'last_provider_data' => null, 'created_at' => Util::now(), 'updated_at' => Util::now(),
        ]);
        try {
            $init = $provider->initialize([
                'reference' => $ourRef, 'amountXaf' => (int) $order['total_xaf'], 'description' => 'Commande ' . substr($orderId, 0, 8),
                'name' => (string) $order['display_name'], 'phone' => $order['phone'], 'email' => $order['email'],
                'callbackUrl' => App::publicUrl() . '/api/payments/return',
            ]);
        } catch (\Throwable $e) {
            $db->run("UPDATE payments SET status='failed', updated_at=? WHERE id=?", [Util::now(), $paymentId]);
            throw new AppError(502, 'payment_provider_unavailable', $e->getMessage());
        }
        $db->run("UPDATE payments SET provider_reference=?, checkout_url=?, status='pending', updated_at=? WHERE id=?",
            [$init['providerReference'], $init['checkoutUrl'], Util::now(), $paymentId]);
        App::audit($buyerId, 'payment.start', 'payment', $paymentId);
        return ['id' => $paymentId, 'reference' => $ourRef, 'providerReference' => $init['providerReference'], 'checkoutUrl' => $init['checkoutUrl']];
    }

    // -------------------------------------------------------- Tâches planifiées
    /** Annule les commandes non payées après le délai réglé (l'article redevient disponible). */
    public static function expirePending(): int
    {
        $db = App::$db;
        $ttl = max(5, App::$settings->int('orders.pending_ttl_min'));
        $n = 0;
        foreach ($db->all("SELECT id FROM orders WHERE status='pending_payment' AND created_at < ? LIMIT 200", [Util::now(-$ttl * 60)]) as $row) {
            $n += $db->tx(function (Db $db) use ($row): int {
                $o = self::lock($db, (string) $row['id']);
                if ($o['status'] !== 'pending_payment') return 0;
                // Un paiement peut être en cours : on ne coupe pas une session de moins de 30 min.
                if ($db->one("SELECT id FROM payments WHERE order_id=? AND status='pending' AND created_at > ?", [$o['id'], Util::now(-1800)])) return 0;
                self::cancelLocked($db, $o, null, 'expiration');
                return 1;
            });
        }
        return $n;
    }

    /** Libère automatiquement le séquestre N jours après paiement sans litige (0 = désactivé). */
    public static function autoRelease(): int
    {
        $days = App::$settings->int('orders.auto_release_days');
        if ($days < 1) return 0;
        $db = App::$db;
        $n = 0;
        foreach ($db->all("SELECT id FROM orders WHERE status='paid' AND paid_at < ? LIMIT 200", [Util::now(-$days * 86400)]) as $row) {
            $n += $db->tx(function (Db $db) use ($row): int {
                $o = self::lock($db, (string) $row['id']);
                if ($o['status'] !== 'paid') return 0;
                self::complete($db, $o, null, 'libération automatique');
                return 1;
            });
        }
        return $n;
    }

    // ---------------------------------------------------------------- Routes
    public static function routes(): void
    {
        $auth = ['auth' => true];
        $admin = ['auth' => ['admin']];
        $db = fn (): Db => App::$db;

        // Ce que l'app doit proposer à l'écran de paiement.
        App::route('GET', '/payments/options', function () {
            $p = Payments::provider();
            return [
                'online' => $p !== null, 'mobileMoney' => $p !== null, 'cash' => App::$settings->bool('payments.cash_enabled'),
                'buyerFeeBps' => App::$settings->int('fees.buyer_bps'), 'buyerFeeFixedXaf' => App::$settings->int('fees.buyer_fixed_xaf'),
            ];
        });

        // Achat d'une annonce de seconde main (au prix affiché ou au prix d'une offre acceptée).
        App::route('POST', '/orders', function (Req $r) use ($db) {
            $b = $r->body();
            $listingId = $b->uuid('listingId');
            $offerId = $b->optUuid('offerId');
            $buyerId = $r->uid();
            $key = $r->idempotencyKey();
            if ($replay = self::findReplay($buyerId, $key)) return self::view($replay);
            $isAdmin = ($r->user['role'] ?? '') === 'admin';
            $order = $db()->tx(function (Db $db) use ($listingId, $offerId, $buyerId, $key, $isAdmin): array {
                $l = $db->one('SELECT seller_id, price_xaf, status, title, is_demo FROM listings WHERE id=?' . $db->lock(), [$listingId]);
                if (!$l) throw AppError::notFound('listing_not_found');
                // Annonce d'exemple : seul un administrateur peut la « commander » (simulation).
                if ((int) $l['is_demo'] && !$isAdmin) throw AppError::forbidden('demo_listing');
                if ($l['seller_id'] === $buyerId) throw AppError::forbidden('cannot_buy_own_listing');
                if ($l['status'] !== 'active') throw AppError::conflict('listing_unavailable');
                $price = (int) $l['price_xaf'];
                if ($offerId) {
                    $offer = $db->one('SELECT f.amount_xaf, f.status, c.buyer_id, c.listing_id FROM offers f
                                       JOIN conversations c ON c.id = f.conversation_id WHERE f.id=?' . $db->lock(), [$offerId]);
                    if (!$offer || $offer['buyer_id'] !== $buyerId || $offer['listing_id'] !== $listingId) throw AppError::notFound('offer_not_found');
                    if ($offer['status'] !== 'accepted') throw AppError::conflict('offer_not_accepted');
                    $price = (int) $offer['amount_xaf'];
                    $db->run("UPDATE offers SET status='used' WHERE id=?", [$offerId]);
                }
                $row = self::insert($db, [
                    'buyerId' => $buyerId, 'sellerId' => (string) $l['seller_id'], 'kind' => 'listing', 'listingId' => $listingId,
                    'items' => [['name' => $l['title'], 'qty' => 1, 'unitPriceXaf' => $price]],
                    'itemPriceXaf' => $price, 'idempotencyKey' => $key, 'offerId' => $offerId,
                ]);
                // L'article est réservé dans la même transaction : aucune double vente possible.
                $db->run("UPDATE listings SET status='reserved', updated_at=? WHERE id=?", [Util::now(), $listingId]);
                return $row;
            });
            $r->status = 201;
            return self::view($order);
        }, $auth);

        App::route('GET', '/orders', function (Req $r) use ($db) {
            $role = $r->query()->enum('role', ['buyer', 'seller', 'all'], 'all');
            $uid = $r->uid();
            [$where, $args] = match ($role) {
                'buyer' => ['buyer_id=?', [$uid]],
                'seller' => ['seller_id=?', [$uid]],
                default => ['(buyer_id=? OR seller_id=?)', [$uid, $uid]],
            };
            return ['items' => array_map([self::class, 'view'], $db()->all("SELECT * FROM orders WHERE $where ORDER BY created_at DESC LIMIT 100", $args))];
        }, $auth);

        App::route('GET', '/orders/{id}', function (Req $r) use ($db) {
            $o = $db()->one('SELECT * FROM orders WHERE id=?', [$r->id()]);
            if (!$o || ($o['buyer_id'] !== $r->uid() && $o['seller_id'] !== $r->uid())) throw AppError::notFound();
            $other = $db()->one('SELECT display_name, phone FROM users WHERE id=?', [$o['buyer_id'] === $r->uid() ? $o['seller_id'] : $o['buyer_id']]);
            $view = self::view($o);
            $view['otherName'] = $other['display_name'] ?? null;
            // Le numéro de l'autre partie n'est montré que lorsqu'il faut se retrouver pour la remise.
            $view['otherPhone'] = in_array($o['status'], ['cash_due', 'paid'], true) ? ($other['phone'] ?? null) : null;
            return $view;
        }, $auth);

        // Paiement en ligne — page sécurisée du prestataire.
        App::route('POST', '/orders/{id}/pay', function (Req $r) {
            $p = self::openPayment($r->uid(), $r->id());
            return ['reference' => $p['reference'], 'checkoutUrl' => $p['checkoutUrl']];
        }, $auth + ['limit' => [20, 60]]);

        // Paiement en ligne — demande envoyée directement sur le téléphone (Orange Money / MTN MoMo).
        App::route('POST', '/orders/{id}/pay-mobile', function (Req $r) {
            $phone = $r->body()->phone('phone');
            $p = self::openPayment($r->uid(), $r->id());
            try {
                $res = Payments::provider()?->chargeMobile($p['providerReference'], $phone);
            } catch (\Throwable $e) {
                throw new AppError(502, 'payment_provider_unavailable', $e->getMessage());
            }
            return ['reference' => $p['reference'], 'status' => $res['status'] ?? 'processing'];
        }, $auth + ['limit' => [10, 60]]);

        // Payer à la remise (espèces ou Mobile Money de la main à la main) : pas de séquestre, pas de frais.
        App::route('POST', '/orders/{id}/pay-cash', function (Req $r) use ($db) {
            if (!App::$settings->bool('payments.cash_enabled')) throw AppError::forbidden('cash_not_enabled');
            $uid = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $uid): array {
                $o = self::lock($db, $r->id());
                if ($o['buyer_id'] !== $uid) throw AppError::notFound();
                if ($o['status'] !== 'pending_payment') throw AppError::conflict('order_not_payable');
                if ($db->one("SELECT id FROM payments WHERE order_id=? AND status='succeeded'", [$o['id']])) throw AppError::conflict('order_not_payable');
                $db->run("UPDATE orders SET status='cash_due', payment_method='cash', buyer_fee_xaf=0, total_xaf=item_price_xaf, updated_at=? WHERE id=?", [Util::now(), $o['id']]);
                App::audit($uid, 'order.cash_chosen', 'order', (string) $o['id']);
                App::notify((string) $o['seller_id'], 'Nouvelle commande — paiement à la remise',
                    'Une ' . self::KIND_LABEL[$o['kind']] . ' est confirmée. L\'acheteur te paie directement à la remise.', "/orders/{$o['id']}", true);
                return self::view((array) $db->one('SELECT * FROM orders WHERE id=?', [$o['id']]));
            });
        }, $auth);

        // L'acheteur confirme la réception.
        App::route('POST', '/orders/{id}/confirm', function (Req $r) use ($db) {
            $uid = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $uid): array {
                $o = self::lock($db, $r->id());
                if ($o['buyer_id'] !== $uid) throw AppError::notFound();
                if (!in_array($o['status'], ['paid', 'cash_due'], true)) throw AppError::conflict('order_not_confirmable');
                self::complete($db, $o, $uid, 'confirmation acheteur');
                return self::view(['status' => 'completed'] + $o);
            });
        }, $auth);

        App::route('POST', '/orders/{id}/cancel', function (Req $r) use ($db) {
            $uid = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $uid): array {
                $o = self::lock($db, $r->id());
                if ($o['buyer_id'] !== $uid && $o['seller_id'] !== $uid) throw AppError::notFound();
                if (!in_array($o['status'], ['pending_payment', 'cash_due'], true)) throw AppError::conflict('order_not_cancellable');
                self::cancelLocked($db, $o, $uid, 'utilisateur');
                if ($o['status'] === 'cash_due') {
                    App::notify((string) ($uid === $o['buyer_id'] ? $o['seller_id'] : $o['buyer_id']), 'Commande annulée', 'La commande à payer à la remise a été annulée.', "/orders/{$o['id']}");
                }
                return self::view(['status' => 'cancelled'] + $o);
            });
        }, $auth);

        App::route('POST', '/orders/{id}/dispute', function (Req $r) use ($db) {
            $reason = $r->body()->str('reason', 10, 1000);
            $uid = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $uid, $reason): array {
                $o = self::lock($db, $r->id());
                if ($o['buyer_id'] !== $uid) throw AppError::notFound();
                if ($o['status'] !== 'paid') throw AppError::conflict('order_not_disputable');
                $db->run("UPDATE orders SET status='disputed', updated_at=? WHERE id=?", [Util::now(), $o['id']]);
                App::audit($uid, 'order.disputed', 'order', (string) $o['id'], ['reason' => $reason]);
                App::notify((string) $o['seller_id'], 'Litige ouvert', 'L\'acheteur a signalé un problème. Notre équipe va examiner la commande.', "/orders/{$o['id']}", true);
                return self::view(['status' => 'disputed'] + $o);
            });
        }, $auth);

        // Le vendeur / commerçant fait avancer la préparation ou la livraison.
        App::route('POST', '/orders/{id}/fulfillment', function (Req $r) use ($db) {
            $step = $r->body()->enum('step', self::STEPS);
            $uid = $r->uid();
            return $db()->tx(function (Db $db) use ($r, $uid, $step): array {
                $o = self::lock($db, $r->id());
                if ($o['seller_id'] !== $uid) throw AppError::notFound();
                if (!in_array($o['status'], ['paid', 'cash_due'], true)) throw AppError::conflict('order_not_paid');
                if ($o['fulfillment'] && array_search($step, self::STEPS, true) <= array_search($o['fulfillment'], self::STEPS, true)) throw AppError::conflict('invalid_transition');
                $db->run('UPDATE orders SET fulfillment=?, updated_at=? WHERE id=?', [$step, Util::now(), $o['id']]);
                $labels = ['accepted' => 'Ta commande est acceptée', 'preparing' => 'Ta commande est en préparation', 'ready' => 'Ta commande est prête',
                           'delivering' => 'Ta commande est en route', 'delivered' => 'Commande livrée : confirme la réception'];
                App::notify((string) $o['buyer_id'], $labels[$step], 'Suis ta commande dans l\'app.', "/orders/{$o['id']}");
                return self::view(['fulfillment' => $step] + $o);
            });
        }, $auth);

        // ---------------------------------------------------------------- Admin
        App::route('POST', '/admin/orders/{id}/release', function (Req $r) use ($db) {
            return $db()->tx(function (Db $db) use ($r): array {
                $o = self::lock($db, $r->id());
                if (!in_array($o['status'], ['paid', 'disputed'], true)) throw AppError::conflict('order_not_releasable');
                self::complete($db, $o, $r->uid(), 'décision admin');
                return self::view(['status' => 'completed'] + $o);
            });
        }, $admin);

        // Rembourse l'acheteur (écriture comptable). Le virement retour se fait depuis le tableau de bord du prestataire.
        App::route('POST', '/admin/orders/{id}/refund', function (Req $r) use ($db) {
            return $db()->tx(function (Db $db) use ($r): array {
                $o = self::lock($db, $r->id());
                if (!in_array($o['status'], ['paid', 'disputed'], true)) throw AppError::conflict('order_not_refundable');
                Ledger::post($db, 'remboursement acheteur', (string) $o['id'], [['escrow', (int) $o['total_xaf']], ['psp:clearing', -(int) $o['total_xaf']]]);
                $db->run("UPDATE orders SET status='refunded', updated_at=? WHERE id=?", [Util::now(), $o['id']]);
                self::releaseReservation($db, $o);
                $db->run("UPDATE payments SET status='refunded', updated_at=? WHERE order_id=? AND status='succeeded'", [Util::now(), $o['id']]);
                App::audit($r->uid(), 'order.refunded', 'order', (string) $o['id']);
                App::notify((string) $o['buyer_id'], 'Remboursement validé', "{$o['total_xaf']} FCFA vont t'être reversés.", "/orders/{$o['id']}", true);
                return self::view(['status' => 'refunded'] + $o);
            });
        }, $admin);

        App::route('GET', '/admin/disputes', function () use ($db) {
            $items = [];
            foreach ($db()->all("SELECT id, kind, total_xaf, updated_at FROM orders WHERE status='disputed' ORDER BY updated_at") as $o) {
                $a = $db()->one("SELECT meta FROM audit_log WHERE entity='order' AND entity_id=? AND action='order.disputed' ORDER BY id DESC LIMIT 1", [$o['id']]);
                $items[] = ['id' => $o['id'], 'kind' => $o['kind'], 'totalXaf' => (int) $o['total_xaf'], 'updatedAt' => Util::iso((string) $o['updated_at']),
                            'reason' => json_decode((string) ($a['meta'] ?? '{}'), true)['reason'] ?? null];
            }
            return ['items' => $items];
        }, $admin);

        // ------------------------------------------------- Suivi des paiements
        App::route('POST', '/payments/{reference}/refresh', function (Req $r) use ($db) {
            $ref = $r->params['reference'];
            if (!preg_match('/^ord_[A-Za-z0-9_-]{8,60}$/', $ref)) throw AppError::bad('validation_failed', 'reference');
            $row = $db()->one('SELECT p.id, o.buyer_id FROM payments p JOIN orders o ON o.id = p.order_id WHERE p.our_reference=?', [$ref]);
            if (!$row || $row['buyer_id'] !== $r->uid()) throw AppError::notFound();
            return ['status' => self::syncPayment((string) $row['id'])];
        }, $auth + ['limit' => [60, 60]]);

        // Webhook prestataire : pas d'authentification utilisateur, la signature HMAC fait foi.
        App::route('POST', '/webhooks/payments', function (Req $r) use ($db) {
            $provider = Payments::provider();
            if (!$provider || $r->raw === '' || !$provider->verifyWebhook($r->raw, $r)) throw AppError::unauthorized('invalid_signature');
            // Anti-rejeu : chaque corps de webhook n'est traité qu'une fois.
            if (!$db()->insertIgnore('webhook_events', ['provider' => $provider->name(), 'body_sha256' => hash('sha256', $r->raw), 'received_at' => Util::now()])) {
                return ['outcome' => 'duplicate'];
            }
            $refs = Payments::refsFromWebhook(json_decode($r->raw, true));
            if (!$refs) return ['outcome' => 'ignored'];
            $m = Db::marks($refs);
            $row = $db()->one("SELECT id FROM payments WHERE provider=? AND (provider_reference IN ($m) OR our_reference IN ($m)) LIMIT 1",
                array_merge([$provider->name()], $refs, $refs));
            if (!$row) return ['outcome' => 'unknown_payment'];
            return ['outcome' => self::syncPayment((string) $row['id'])];
        }, ['limit' => [120, 60]]);

        // Page de retour après paiement (le navigateur y revient) : simple, sans données sensibles.
        App::route('GET', '/payments/return', fn () => new RawResponse(
            '<!doctype html><html lang="fr"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Paiement</title>'
            . '<body style="font-family:system-ui,sans-serif;padding:48px 24px;text-align:center;color:#0E1116"><h2>Merci !</h2>'
            . '<p>Retourne dans l\'application Ovia : ton paiement y est confirmé en quelques secondes.</p></body></html>',
            'text/html; charset=utf-8'));

        App::route('GET', '/me/wallet', function (Req $r) use ($db) {
            // Le porte-monnaie est une dette de la plateforme : solde créditeur (négatif) = disponible.
            return ['currency' => 'XAF', 'availableXaf' => -Ledger::balance($db(), Ledger::wallet($r->uid()))];
        }, $auth);
    }
}
