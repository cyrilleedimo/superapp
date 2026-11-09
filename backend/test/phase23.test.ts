// Tests d'intégration Phases 2 & 3 : médias, messagerie/offres, covoiturage, VTC,
// restaurants/boutiques, retraits, tâches planifiées, notifications.
import sharp from 'sharp';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { freshIp, setup, signup, teardown, type TestEnv } from './helpers.js';
import { balance } from '../src/modules/ledger/ledger.js';
import { makeOrderService } from '../src/modules/orders/service.js';

let env: TestEnv;
type U = Awaited<ReturnType<typeof signup>>;
let admin: U, alice: U, bob: U, carl: U;
const key = () => `idem_${Math.random().toString(36).slice(2)}${Date.now()}`;

/** Paie une commande via le faux prestataire + webhook signé. */
async function payOrder(orderId: string, buyer: U) {
  const pay = await env.app.inject({ method: 'POST', url: `/orders/${orderId}/pay`, headers: buyer.auth });
  expect(pay.statusCode).toBe(200);
  const ref = (await env.ctx.db.query('SELECT provider_reference FROM payments WHERE order_id=$1 ORDER BY created_at DESC LIMIT 1', [orderId])).rows[0].provider_reference;
  env.psp.simulate(ref, 'succeeded');
  const body = JSON.stringify({ type: 'payment.complete', data: { reference: ref }, t: Date.now() + Math.random() });
  const w = await env.app.inject({ method: 'POST', url: '/webhooks/payments', payload: body,
    headers: { 'content-type': 'application/json', 'x-sandbox-signature': env.psp.sign(body) } });
  expect(w.json().outcome).toBe('succeeded');
}

beforeAll(async () => {
  env = await setup();
  admin = await signup(env, '+237699000001', 'Admin');
  await env.ctx.db.query(`UPDATE users SET role='admin' WHERE id=$1`, [admin.id]);
  const login = await env.app.inject({ method: 'POST', url: '/auth/login', remoteAddress: freshIp(),
    payload: { phone: '+237699000001', password: 'motdepasse-solide-42' } });
  admin.auth = { authorization: `Bearer ${login.json().accessToken}` };
  alice = await signup(env, '+237699000002', 'Alice');
  bob = await signup(env, '+237699000003', 'Bob');
  carl = await signup(env, '+237699000004', 'Carl');
});
afterAll(async () => { await teardown(env); });

describe('médias', () => {
  it('ré-encode une image en WebP et la sert', async () => {
    const png = await sharp({ create: { width: 40, height: 30, channels: 3, background: '#2B3CF0' } }).png().toBuffer();
    const r = await env.app.inject({ method: 'POST', url: '/media', payload: png,
      headers: { ...alice.auth, 'content-type': 'image/png' } });
    expect(r.statusCode).toBe(201);
    const g = await env.app.inject({ method: 'GET', url: `/media/${r.json().id}` });
    expect(g.statusCode).toBe(200);
    expect(g.headers['content-type']).toContain('image/webp');
    // L'URL renvoyée est acceptée comme photo d'annonce.
    const l = await env.app.inject({ method: 'POST', url: '/listings', headers: alice.auth, payload: {
      title: 'Chaise en bois', category: 'home', condition: 'good', priceXaf: 15000, city: 'Douala', photos: [r.json().url] } });
    expect(l.statusCode).toBe(201);
  });

  it('refuse un fichier qui se fait passer pour une image', async () => {
    const r = await env.app.inject({ method: 'POST', url: '/media', payload: Buffer.from('<?php system($_GET[1]); ?>'),
      headers: { ...alice.auth, 'content-type': 'image/png' } });
    expect(r.statusCode).toBe(415);
  });
});

describe('messagerie et offres', () => {
  it('offre acceptée → achat au prix négocié', async () => {
    const l = (await env.app.inject({ method: 'POST', url: '/listings', headers: alice.auth, payload: {
      title: 'Sneakers blanches', category: 'men', condition: 'very_good', priceXaf: 20000, city: 'Douala' } })).json();
    const c = (await env.app.inject({ method: 'POST', url: '/conversations', headers: bob.auth, payload: { listingId: l.id } })).json();
    await env.app.inject({ method: 'POST', url: `/conversations/${c.id}/messages`, headers: bob.auth, payload: { body: 'Toujours dispo ?' } });
    // Une offre au-dessus du prix n'a pas de sens.
    const tooHigh = await env.app.inject({ method: 'POST', url: `/conversations/${c.id}/offers`, headers: bob.auth, payload: { amountXaf: 25000 } });
    expect(tooHigh.statusCode).toBe(409);
    const offer = (await env.app.inject({ method: 'POST', url: `/conversations/${c.id}/offers`, headers: bob.auth, payload: { amountXaf: 16000 } })).json();
    // L'acheteur ne peut pas accepter sa propre offre.
    expect((await env.app.inject({ method: 'POST', url: `/offers/${offer.id}/decision`, headers: bob.auth, payload: { accept: true } })).statusCode).toBe(404);
    expect((await env.app.inject({ method: 'POST', url: `/offers/${offer.id}/decision`, headers: alice.auth, payload: { accept: true } })).statusCode).toBe(200);
    const msgs = (await env.app.inject({ method: 'GET', url: `/conversations/${c.id}/messages`, headers: alice.auth })).json().items;
    expect(msgs.length).toBe(3);
    // Un tiers ne lit pas la conversation.
    expect((await env.app.inject({ method: 'GET', url: `/conversations/${c.id}/messages`, headers: carl.auth })).statusCode).toBe(404);
    // Carl ne peut pas utiliser l'offre de Bob.
    const steal = await env.app.inject({ method: 'POST', url: '/orders', headers: { ...carl.auth, 'idempotency-key': key() },
      payload: { listingId: l.id, offerId: offer.id } });
    expect(steal.statusCode).toBe(404);
    const o = await env.app.inject({ method: 'POST', url: '/orders', headers: { ...bob.auth, 'idempotency-key': key() },
      payload: { listingId: l.id, offerId: offer.id } });
    expect(o.statusCode).toBe(201);
    expect(o.json().itemPriceXaf).toBe(16000);
    expect(o.json().totalXaf).toBe(17600);
  });
});

describe('covoiturage', () => {
  it('réserve des places, annule, puis paie et libère vers le conducteur', async () => {
    const depart = new Date(Date.now() + 24 * 3600_000).toISOString();
    const t = (await env.app.inject({ method: 'POST', url: '/trips', headers: carl.auth, payload: {
      fromCity: 'Douala', toCity: 'Yaoundé', departAt: depart, seats: 3, pricePerSeatXaf: 6000 } })).json();
    const search = (await env.app.inject({ method: 'GET', url: '/trips?from=douala&to=yaoundé' })).json().items;
    expect(search.map((x: { id: string }) => x.id)).toContain(t.id);

    const tooMany = await env.app.inject({ method: 'POST', url: `/trips/${t.id}/book`, headers: { ...bob.auth, 'idempotency-key': key() }, payload: { seats: 4 } });
    expect(tooMany.statusCode).toBe(409);
    const b1 = (await env.app.inject({ method: 'POST', url: `/trips/${t.id}/book`, headers: { ...bob.auth, 'idempotency-key': key() }, payload: { seats: 2 } })).json();
    expect(b1.itemPriceXaf).toBe(12000);
    const seats = async () => (await env.ctx.db.query('SELECT seats_left FROM trips WHERE id=$1', [t.id])).rows[0].seats_left;
    expect(await seats()).toBe(1);
    await env.app.inject({ method: 'POST', url: `/orders/${b1.id}/cancel`, headers: bob.auth });
    expect(await seats()).toBe(3);

    const b2 = (await env.app.inject({ method: 'POST', url: `/trips/${t.id}/book`, headers: { ...alice.auth, 'idempotency-key': key() }, payload: { seats: 1 } })).json();
    await payOrder(b2.id, alice);
    await env.app.inject({ method: 'POST', url: `/orders/${b2.id}/confirm`, headers: alice.auth });
    expect((await env.app.inject({ method: 'GET', url: '/me/wallet', headers: carl.auth })).json().availableXaf).toBe(6000);
  });
});

describe('VTC', () => {
  const pickup = { text: 'Akwa, Douala', lat: 4.0511, lng: 9.7679 };
  const dropoff = { text: 'Bonamoussadi, Douala', lat: 4.0889, lng: 9.7356 };

  it('estime, attribue au premier chauffeur vérifié, puis suit les statuts', async () => {
    const est = (await env.app.inject({ method: 'POST', url: '/rides/estimate', payload: { pickup, dropoff } })).json();
    expect(est.distanceKm).toBeGreaterThan(4);
    expect(est.distanceKm).toBeLessThan(7);
    expect(est.fareXaf).toBe(Math.ceil(500 + est.distanceKm * 200));

    await env.app.inject({ method: 'POST', url: '/drivers/apply', headers: carl.auth, payload: { vehicle: 'Toyota Corolla grise', plate: 'LT 123 AB' } });
    // Non vérifié : ne peut pas passer en ligne.
    expect((await env.app.inject({ method: 'POST', url: '/drivers/me/status', headers: carl.auth,
      payload: { online: true, lat: 4.052, lng: 9.768 } })).statusCode).toBe(403);
    await env.app.inject({ method: 'POST', url: `/admin/drivers/${carl.id}/verify`, headers: admin.auth, payload: { verified: true } });
    expect((await env.app.inject({ method: 'POST', url: '/drivers/me/status', headers: carl.auth,
      payload: { online: true, lat: 4.052, lng: 9.768 } })).statusCode).toBe(200);

    const ride = (await env.app.inject({ method: 'POST', url: '/rides', headers: bob.auth, payload: { pickup, dropoff } })).json();
    expect((await env.app.inject({ method: 'POST', url: '/rides', headers: bob.auth, payload: { pickup, dropoff } })).statusCode).toBe(409);
    const nearby = (await env.app.inject({ method: 'GET', url: '/rides/nearby', headers: carl.auth })).json().items;
    expect(nearby[0].id).toBe(ride.id);
    expect((await env.app.inject({ method: 'POST', url: `/rides/${ride.id}/accept`, headers: carl.auth })).statusCode).toBe(200);
    // Statut hors séquence refusé.
    expect((await env.app.inject({ method: 'POST', url: `/rides/${ride.id}/status`, headers: carl.auth, payload: { status: 'completed' } })).statusCode).toBe(409);
    for (const s of ['arrived', 'in_progress', 'completed']) {
      const r = await env.app.inject({ method: 'POST', url: `/rides/${ride.id}/status`, headers: carl.auth, payload: { status: s } });
      expect(r.json().status).toBe(s);
    }
    expect((await env.app.inject({ method: 'GET', url: '/rides/current', headers: bob.auth })).json().ride).toBeNull();
  });
});

describe('restaurants et boutiques', () => {
  it('commerce validé par admin, stock décrémenté, livraison suivie, commerçant payé', async () => {
    const s = (await env.app.inject({ method: 'POST', url: '/stores', headers: alice.auth, payload: {
      kind: 'shop', name: 'Atelier Alice', city: 'Douala', deliveryFeeXaf: 1000 } })).json();
    // Invisible tant qu'il n'est pas validé.
    expect((await env.app.inject({ method: 'GET', url: `/stores/${s.id}` })).statusCode).toBe(404);
    // Un non-admin ne peut pas valider.
    expect((await env.app.inject({ method: 'POST', url: `/admin/stores/${s.id}/approve`, headers: bob.auth })).statusCode).toBe(403);
    await env.app.inject({ method: 'POST', url: `/admin/stores/${s.id}/approve`, headers: admin.auth });
    const p = (await env.app.inject({ method: 'POST', url: `/stores/${s.id}/products`, headers: alice.auth, payload: {
      name: 'Casque audio', priceXaf: 15000, stock: 2, category: 'Électronique' } })).json();
    // Bob ne peut pas modifier le catalogue d'Alice.
    expect((await env.app.inject({ method: 'PATCH', url: `/products/${p.id}`, headers: bob.auth, payload: { priceXaf: 1 } })).statusCode).toBe(403);

    const over = await env.app.inject({ method: 'POST', url: `/stores/${s.id}/orders`, headers: { ...bob.auth, 'idempotency-key': key() },
      payload: { items: [{ productId: p.id, qty: 3 }] } });
    expect(over.statusCode).toBe(409);
    const o = (await env.app.inject({ method: 'POST', url: `/stores/${s.id}/orders`, headers: { ...bob.auth, 'idempotency-key': key() },
      payload: { items: [{ productId: p.id, qty: 2 }] } })).json();
    expect(o.kind).toBe('shop');
    expect(o.itemPriceXaf).toBe(31000); // 2 × 15 000 + 1 000 de livraison
    expect((await env.ctx.db.query('SELECT stock FROM products WHERE id=$1', [p.id])).rows[0].stock).toBe(0);

    // Avant paiement, le commerçant ne peut pas faire avancer la commande.
    expect((await env.app.inject({ method: 'POST', url: `/orders/${o.id}/fulfillment`, headers: alice.auth, payload: { step: 'accepted' } })).statusCode).toBe(409);
    await payOrder(o.id, bob);
    for (const step of ['accepted', 'preparing', 'delivering', 'delivered']) {
      const r = await env.app.inject({ method: 'POST', url: `/orders/${o.id}/fulfillment`, headers: alice.auth, payload: { step } });
      expect(r.statusCode).toBe(200);
    }
    const before = (await env.app.inject({ method: 'GET', url: '/me/wallet', headers: alice.auth })).json().availableXaf;
    await env.app.inject({ method: 'POST', url: `/orders/${o.id}/confirm`, headers: bob.auth });
    const after = (await env.app.inject({ method: 'GET', url: '/me/wallet', headers: alice.auth })).json().availableXaf;
    expect(after - before).toBe(31000);
    const notes = (await env.app.inject({ method: 'GET', url: '/notifications', headers: bob.auth })).json();
    expect(notes.items.some((n: { title: string }) => n.title.includes('livrée'))).toBe(true);
  });

  it('annuler une commande boutique remet le stock', async () => {
    const s = (await env.app.inject({ method: 'POST', url: '/stores', headers: carl.auth, payload: { kind: 'restaurant', name: 'Chez Carl', city: 'Douala' } })).json();
    await env.app.inject({ method: 'POST', url: `/admin/stores/${s.id}/approve`, headers: admin.auth });
    const p = (await env.app.inject({ method: 'POST', url: `/stores/${s.id}/products`, headers: carl.auth, payload: { name: 'Plat du jour', priceXaf: 3500 } })).json();
    const o = (await env.app.inject({ method: 'POST', url: `/stores/${s.id}/orders`, headers: { ...bob.auth, 'idempotency-key': key() },
      payload: { items: [{ productId: p.id, qty: 2 }] } })).json();
    expect(o.kind).toBe('food');
    expect(o.itemPriceXaf).toBe(7000);
    // Le commerce fermé ne prend plus de commande.
    await env.app.inject({ method: 'PATCH', url: `/stores/${s.id}`, headers: carl.auth, payload: { isOpen: false } });
    expect((await env.app.inject({ method: 'POST', url: `/stores/${s.id}/orders`, headers: { ...bob.auth, 'idempotency-key': key() },
      payload: { items: [{ productId: p.id, qty: 1 }] } })).statusCode).toBe(409);
  });
});

describe('retraits', () => {
  it('refuse un retrait supérieur au solde, puis verse et équilibre le grand livre', async () => {
    const wallet = (await env.app.inject({ method: 'GET', url: '/me/wallet', headers: alice.auth })).json().availableXaf;
    expect(wallet).toBeGreaterThan(0);
    const tooMuch = await env.app.inject({ method: 'POST', url: '/payouts', headers: alice.auth,
      payload: { amountXaf: wallet + 1, msisdn: '+237699000002', channel: 'orange_money' } });
    expect(tooMuch.statusCode).toBe(409);
    // Deux demandes simultanées du solde entier : une seule passe.
    const req = () => env.app.inject({ method: 'POST', url: '/payouts', headers: alice.auth,
      payload: { amountXaf: wallet, msisdn: '+237699000002', channel: 'orange_money' } });
    const [a, b] = await Promise.all([req(), req()] as const);
    expect([a.statusCode, b.statusCode].sort()).toEqual([201, 409]);
    expect((await env.app.inject({ method: 'GET', url: '/me/wallet', headers: alice.auth })).json().availableXaf).toBe(0);
    const id = (a.statusCode === 201 ? a : b).json().id;
    await env.app.inject({ method: 'POST', url: `/admin/payouts/${id}/decision`, headers: admin.auth, payload: { paid: true } });
    expect(await balance(env.ctx.db, 'payouts:pending')).toBe(0);
    const total = (await env.ctx.db.query('SELECT coalesce(sum(amount_xaf),0)::bigint AS s FROM ledger_entries')).rows[0].s;
    expect(total).toBe(0);
  });
});

describe('tâches planifiées', () => {
  it('expire les commandes impayées et libère l\'article', async () => {
    const l = (await env.app.inject({ method: 'POST', url: '/listings', headers: alice.auth, payload: {
      title: 'Lampe de bureau', category: 'home', condition: 'good', priceXaf: 8000, city: 'Douala' } })).json();
    const o = (await env.app.inject({ method: 'POST', url: '/orders', headers: { ...bob.auth, 'idempotency-key': key() }, payload: { listingId: l.id } })).json();
    await env.ctx.db.query(`UPDATE orders SET created_at = now() - interval '2 hours' WHERE id=$1`, [o.id]);
    const n = await makeOrderService(env.ctx).expirePending();
    expect(n).toBeGreaterThanOrEqual(1);
    expect((await env.app.inject({ method: 'GET', url: `/listings/${l.id}` })).json().status).toBe('active');
  });

  it('libère automatiquement le séquestre après le délai', async () => {
    const l = (await env.app.inject({ method: 'POST', url: '/listings', headers: carl.auth, payload: {
      title: 'Montre', category: 'men', condition: 'good', priceXaf: 9000, city: 'Douala' } })).json();
    const o = (await env.app.inject({ method: 'POST', url: '/orders', headers: { ...bob.auth, 'idempotency-key': key() }, payload: { listingId: l.id } })).json();
    await payOrder(o.id, bob);
    await env.ctx.db.query(`UPDATE orders SET paid_at = now() - interval '8 days' WHERE id=$1`, [o.id]);
    await makeOrderService(env.ctx).autoRelease();
    expect((await env.app.inject({ method: 'GET', url: `/orders/${o.id}`, headers: bob.auth })).json().status).toBe('completed');
  });
});

describe('voyages', () => {
  it('répond clairement quand aucun partenaire de données n\'est configuré', async () => {
    const r = await env.app.inject({ method: 'GET', url: '/travel/flights?from=DLA&to=CDG&departDate=2026-12-14' });
    expect(r.statusCode).toBe(503);
    expect(r.json().error).toBe('travel_not_configured');
  });
});
