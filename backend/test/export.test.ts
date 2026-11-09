// Miroir lisible « un fichier par utilisateur ».
import { mkdtemp, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { setup, signup, teardown, type TestEnv } from './helpers.js';
import { exportAll, exportUser, safeFileBase } from '../src/lib/userExport.js';

let env: TestEnv;
beforeAll(async () => { env = await setup(); });
afterAll(async () => { await teardown(env); });

describe('noms de fichiers', () => {
  it('neutralise chemins, caractères interdits et noms réservés Windows', () => {
    expect(safeFileBase('..\\..\\Windows\\system32')).toBe('Windows system32');
    expect(safeFileBase('Paul: "Edimo" <test>?')).toBe('Paul Edimo test');
    expect(safeFileBase('CON')).toBe('Utilisateur CON');
    expect(safeFileBase('Aïcha N.')).toBe('Aïcha N');
  });
});

describe('export', () => {
  it('un fichier par utilisateur, homonymes distingués, aucun secret', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'export-'));
    const a = await signup(env, '+237698000001', 'Paul Edimo');
    const b = await signup(env, '+237698000002', 'paul edimo');
    await env.app.inject({ method: 'POST', url: '/listings', headers: a.auth, payload: {
      title: 'Veste en lin', category: 'women', condition: 'good', priceXaf: 12000, city: 'Douala' } });
    expect(await exportUser(env.ctx.db, dir, a.id)).toBe('Paul Edimo.json');
    expect(await exportUser(env.ctx.db, dir, b.id)).toBe('paul edimo (2).json');
    // Nom stable : un nouvel export réécrit le même fichier.
    expect(await exportUser(env.ctx.db, dir, a.id)).toBe('Paul Edimo.json');
    await exportAll(env.ctx.db, dir);
    const files = (await readdir(dir)).filter((f) => f.endsWith('.json'));
    expect(files).toContain('Paul Edimo.json');
    const raw = await readFile(join(dir, 'Paul Edimo.json'), 'utf8');
    const json = JSON.parse(raw);
    expect(json.profil.telephone).toBe('+237698000001');
    expect(json.annonces[0].titre).toBe('Veste en lin');
    expect(raw).not.toMatch(/argon2|password|token/i);
    expect((await readdir(dir)).some((f) => f.endsWith('.tmp'))).toBe(false);
  });
});
