// Tests d'intégration de bout en bout sur PostgreSQL réel.
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { freshIp, setup, signup, teardown, type TestEnv } from './helpers.js';
import { balance, walletAccount } from '../src/modules/ledger/ledger.js';

let env: TestEnv;
beforeAll(async () => { env = await setup(); });
afterAll(async () => { await teardown(env); });

const key = () => `idem_${Math.random().toString(36).slice(2)}${Date.now()}`;

describe('authentification', () => {
  it('inscription → OTP → connexion → /me', async () => {
    const u = await signup(env, '+237690000001', 'Aïcha');
    expect(u.id).toMatch(/^[0-9a-f-]{36}$/);
    const login = await env.app.inject({ method: 'POST', url: '/auth/login', remoteAddress: freshIp(),
      payload: { phone: '+237690000001', password: 'motdepasse-solide-42' } });
    expect(login.statusCode).toBe(200);
  });

  it('refuse un mot de passe trop court et un téléphone non E.164', async () => {
    const r = await env.app.inject({ method: 'POST', url: '/auth/register', remoteAddress: freshIp(),
      payload: { phone: '690000009', password: 'court', displayName: 'X Y' } });
    expect(r.statusCode).toBe(400);
  });

  it('refuse un mauvais code OTP et bloque après 5 essais', async () => {
    const ip = freshIp();
    await env.app.inject({ method: 'POST', url: '/auth/register', remoteAddress: ip,
      payload: { phone: '+237690000002', password: 'motdepasse-solide-42', displayName: 'Bob' } });
    const good = env.sms.lastCodeFor('+237690000002')!;
    const bad = good === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) {
      const r = await env.app.inject({ method: 'POST', url: '/auth/verify-phone', remoteAddress: freshIp(),
        payload: { phone: '+237690000002', code: bad } });
      expect(r.statusCode).toBe(401);
    }
    // Même le bon code est refusé une fois le quota d'essais épuisé.
    const r = await env.app.inject({ method: 'POST', url: '/auth/verify-phone', remoteAddress: freshIp(),
      payload: { phone: '+237690000002', code: good } });
    expect(r.statusCode).toBe(401);
  });

  it('verrouille le compte après 5 mots de passe erronés', async () => {
    await signup(env, '+237690000003');
    for (let i = 0; i < 5; i++) {
      const r = await env.app.inject({ method: 'POST', url: '/auth/login', remoteAddress: freshIp(),
        payload: { phone: '+237690000003', password: 'mauvais-mot-de-passe' } });
      expect(r.statusCode).toBe(401);
    }
    const r = await env.app.inject({ method: 'POST', url: '/auth/login', remoteAddress: freshIp(),
      payload: { phone: '+237690000003', password: 'motdepasse-solide-42' } });
    expect(r.statusCode).toBe(423);
  });

  it('rotation du refresh token et révocation de la famille en cas de réutilisation', async () => {
    const u = await signup(env, '+237690000004');
    const r1 = await env.app.inject({ method: 'POST', url: '/auth/refresh', remoteAddress: freshIp(), payload: { refreshToken: u.refreshToken } });
    expect(r1.statusCode).toBe(200);
    const rotated = r1.json().refreshToken as string;
    // Rejouer l'ancien jeton = vol présumé → 401 et toute la famille est coupée.
    const r2 = await env.app.inject({ method: 'POST', url: '/auth/refresh', remoteAddress: freshIp(), payload: { refreshToken: u.refreshToken } });
    expect(r2.statusCode).toBe(401);
    expect(r2.json().error).toBe('refresh_reuse_detected');
    const r3 = await env.app.inject({ method: 'POST', url: '/auth/refresh', remoteAddress: freshIp(), payload: { refreshToken: rotated } });
    expect(r3.statusCode).toBe(401);
  });

  it('rejette un JWT falsifié', async () => {
    const r = await env.app.inject({ method: 'GET', url: '/me',
      headers: { authorization: 'Bearer eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.' } });
    expect(r.statusCode).toBe(401);
  });
});

describe('seconde main + séquestre', () => {
  let seller: Awaited<ReturnType<typeof signup>>;
  let buyer: Awaited<ReturnType<typeof signup>>;
  let listingId: string;

  beforeAll(async () => {
    seller = await signup(env, '+237690000010', 'Vendeuse');
    buyer = await signup(env, '+237690000011', 'Acheteur');
  });

  it('publie une annonce et la retrouve par recherche plein texte', async () => {
    const r = await env.app.inject({ method: 'POST', url: '/listings', headers: seller.auth, payload: {
      title: 'Veste en lin oversize', description: 'Coupe droite, portée deux fois', category: 'women',
      condition: 'very_good', priceXaf: 12000, city: 'Douala', photos: ['https://cdn.example.com/a.webp'] } });
    expect(r.statusCode).toBe(201);
    listingId = r.json().id;
    const s = await env.app.inject({ method: 'GET', url: '/listings?q=veste&city=douala' });
    expect(s.json().items.map((i: { id: string }) => i.id)).toContain(listingId);
  });

  it('refuse les photos non https et une page de curseur invalide', async () => {
    const r = await env.app.inject({ method: 'POST', url: '/listings', headers: seller.auth, payload: {
      title: 'Test', category: 'men', condition: 'good', priceXaf: 1000, city: 'Douala', photos: ['http://x.com/a.jpg'] } });
    expect(r.statusCode).toBe(400);
    const c = await env.app.inject({ method: 'GET', url: '/listings?cursor=nimportequoi' });
    expect(c.statusCode).toBe(400);
  });

  it('le vendeur ne peut pas acheter sa propre annonce', async () => {
    const r = await env.app.inject({ method: 'POST', url: '/orders', headers: { ...seller.auth, 'idempotency-key': key() }, payload: { listingId } });
    expect(r.statusCode).toBe(403);
  });

  it('parcours complet : commande → paiement → webhook → confirmation → portefeuille vendeur', async () => {
    const k = key();
    const o = await env.app.inject({ method: 'POST', url: '/orders', headers: { ...buyer.auth, 'idempotency-key': k }, payload: { listingId } });
    expect(o.statusCode).toBe(201);
    const order = o.json();
    expect(order.itemPriceXaf).toBe(12000);
    expect(order.buyerFeeXaf).toBe(1200);
    expect(order.totalXaf).toBe(13200);

    // Rejeu de la même requête (réseau instable) : même commande, pas de doublon.
    const replay = await env.app.inject({ method: 'POST', url: '/orders', headers: { ...buyer.auth, 'idempotency-key': k }, payload: { listingId } });
    expect(replay.statusCode).toBe(200);
    expect(replay.json().id).toBe(order.id);

    // Un autre acheteur ne peut plus commander : l'annonce est réservée.
    const other = await signup(env, '+237690000012');
    const blocked = await env.app.inject({ method: 'POST', url: '/orders', headers: { ...other.auth, 'idempotency-key': key() }, payload: { listingId } });
    expect(blocked.statusCode).toBe(409);

    const pay = await env.app.inject({ method: 'POST', url: `/orders/${order.id}/pay`, headers: buyer.auth });
    expect(pay.statusCode).toBe(200);
    expect(pay.json().checkoutUrl).toMatch(/^https:\/\//);
    const ref = (await env.ctx.db.query('SELECT provider_reference FROM payments WHERE order_id=$1', [order.id])).rows[0].provider_reference;

    // Webhook forgé (mauvaise signature) : rejeté, rien ne bouge.
    const body = JSON.stringify({ type: 'payment.complete', data: { reference: ref } });
    const forged = await env.app.inject({ method: 'POST', url: '/webhooks/payments', payload: body,
      headers: { 'content-type': 'application/json', 'x-sandbox-signature': 'deadbeef'.repeat(8) } });
    expect(forged.statusCode).toBe(401);

    // Webhook signé mais le prestataire dit encore « en attente » : la commande reste impayée.
    const early = await env.app.inject({ method: 'POST', url: '/webhooks/payments', payload: body,
      headers: { 'content-type': 'application/json', 'x-sandbox-signature': env.psp.sign(body) } });
    expect(early.json().outcome).toBe('pending');

    // Le prestataire confirme ; nouveau webhook signé.
    env.psp.simulate(ref, 'succeeded');
    const body2 = JSON.stringify({ type: 'payment.complete', data: { reference: ref }, n: 2 });
    const ok = await env.app.inject({ method: 'POST', url: '/webhooks/payments', payload: body2,
      headers: { 'content-type': 'application/json', 'x-sandbox-signature': env.psp.sign(body2) } });
    expect(ok.json().outcome).toBe('succeeded');

    // Rejeu exact du même webhook : ignoré.
    const dup = await env.app.inject({ method: 'POST', url: '/webhooks/payments', payload: body2,
      headers: { 'content-type': 'application/json', 'x-sandbox-signature': env.psp.sign(body2) } });
    expect(dup.json().outcome).toBe('duplicate');

    expect((await env.app.inject({ method: 'GET', url: `/orders/${order.id}`, headers: buyer.auth })).json().status).toBe('paid');
    expect(await balance(env.ctx.db, 'escrow')).toBe(-13200);

    // Le vendeur ne peut pas libérer le séquestre à la place de l'acheteur.
    const sneaky = await env.app.inject({ method: 'POST', url: `/orders/${order.id}/confirm`, headers: seller.auth });
    expect(sneaky.statusCode).toBe(404);

    const conf = await env.app.inject({ method: 'POST', url: `/orders/${order.id}/confirm`, headers: buyer.auth });
    expect(conf.statusCode).toBe(200);
    expect(conf.json().status).toBe('completed');

    expect(await balance(env.ctx.db, 'escrow')).toBe(0);
    expect(await balance(env.ctx.db, 'platform:revenue')).toBe(-1200);
    const wallet = await env.app.inject({ method: 'GET', url: '/me/wallet', headers: seller.auth });
    expect(wallet.json().availableXaf).toBe(12000);
    const listing = await env.app.inject({ method: 'GET', url: `/listings/${listingId}` });
    expect(listing.json().status).toBe('sold');

    // Le grand livre est globalement équilibré.
    const total = (await env.ctx.db.query('SELECT coalesce(sum(amount_xaf),0)::bigint AS s FROM ledger_entries')).rows[0].s;
    expect(total).toBe(0);
  });

  it('un montant payé différent du montant facturé n\'est jamais crédité', async () => {
    const l = await env.app.inject({ method: 'POST', url: '/listings', headers: seller.auth, payload: {
      title: 'Smartphone 128 Go', category: 'electronics', condition: 'good', priceXaf: 85000, city: 'Douala' } });
    const o = (await env.app.inject({ method: 'POST', url: '/orders', headers: { ...buyer.auth, 'idempotency-key': key() },
      payload: { listingId: l.json().id } })).json();
    await env.app.inject({ method: 'POST', url: `/orders/${o.id}/pay`, headers: buyer.auth });
    const ref = (await env.ctx.db.query('SELECT provider_reference FROM payments WHERE order_id=$1', [o.id])).rows[0].provider_reference;
    env.psp.simulate(ref, 'succeeded', 100); // le client n'a payé que 100 FCFA
    const body = JSON.stringify({ data: { reference: ref } });
    const r = await env.app.inject({ method: 'POST', url: '/webhooks/payments', payload: body,
      headers: { 'content-type': 'application/json', 'x-sandbox-signature': env.psp.sign(body) } });
    expect(r.json().outcome).toBe('mismatch');
    const order = (await env.app.inject({ method: 'GET', url: `/orders/${o.id}`, headers: buyer.auth })).json();
    expect(order.status).toBe('pending_payment');
  });

  it('un utilisateur ne voit pas les commandes des autres', async () => {
    const stranger = await signup(env, '+237690000013');
    const mine = (await env.app.inject({ method: 'GET', url: '/orders', headers: buyer.auth })).json().items[0];
    const r = await env.app.inject({ method: 'GET', url: `/orders/${mine.id}`, headers: stranger.auth });
    expect(r.statusCode).toBe(404);
  });

  it('le grand livre refuse toute modification', async () => {
    await expect(env.ctx.db.query('UPDATE ledger_entries SET amount_xaf = 1')).rejects.toThrow(/ajout seul/);
  });

  it('le portefeuille vendeur reflète le compte du grand livre', async () => {
    expect(-(await balance(env.ctx.db, walletAccount(seller.id)))).toBe(12000);
  });
});
