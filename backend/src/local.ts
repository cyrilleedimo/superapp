// Lanceur « serveur sur mon PC » : démarre une base PostgreSQL EMBARQUÉE (aucune
// installation système) dont les données vivent dans PG_DATA_DIR, puis l'API.
//   PG_DATA_DIR   ex. C:\Users\Paul\AppData\Local\Ovia\base-systeme
//   PG_PASSWORD   mot de passe généré à l'installation (dans .env)
//   PG_PORT       port local de la base (défaut 54329, jamais exposé sur Internet)
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import EmbeddedPostgres from 'embedded-postgres';
import pgLib from 'pg';

const dataDir = process.env.PG_DATA_DIR;
const password = process.env.PG_PASSWORD;
const port = Number(process.env.PG_PORT ?? 54329);
if (!dataDir || !password) throw new Error('PG_DATA_DIR et PG_PASSWORD sont requis (voir .env)');

const pg = new EmbeddedPostgres({ databaseDir: dataDir, user: 'postgres', password, port, persistent: true, onLog: () => {} });

// Sous Windows, PostgreSQL refuse de tourner avec des droits administrateur.
// pg_ctl, l'outil officiel, abandonne ces droits (jeton restreint) avant de lancer le serveur.
const isWindows = process.platform === 'win32';
// Le paquet binaire Windows exporte le chemin de pg_ctl (installé seulement sous Windows).
const winPkg = '@embedded-postgres/windows-x64';
const pgCtl: string = isWindows ? ((await import(winPkg)) as { pg_ctl: string }).pg_ctl : '';
const logFile = join(dirname(dataDir), 'postgres.log');

async function startDb() {
  if (!isWindows) return pg.start();
  try {
    execFileSync(pgCtl, ['start', '-D', dataDir!, '-o', `-p ${port} -c listen_addresses=127.0.0.1`, '-l', logFile, '-w', '-t', '90'], { stdio: 'ignore' });
  } catch {
    throw new Error(`La base n'a pas démarré. Détails : ${logFile}`);
  }
}

async function stopDb() {
  if (!isWindows) return pg.stop();
  try { execFileSync(pgCtl, ['stop', '-D', dataDir!, '-m', 'fast', '-w'], { stdio: 'ignore' }); } catch { /* déjà arrêtée */ }
}

const firstRun = !existsSync(join(dataDir, 'PG_VERSION'));
if (firstRun) {
  console.log('Première exécution : création de la base de données…');
  mkdirSync(dirname(dataDir), { recursive: true }); // initdb ne crée que le dernier dossier
  await pg.initialise();
}
// Une base restée allumée après un arrêt brutal est d'abord arrêtée proprement.
if (isWindows && existsSync(join(dataDir, 'postmaster.pid'))) await stopDb();
await startDb();
// Crée la base applicative si besoin (un premier démarrage a pu être interrompu).
// Connexion explicite en IPv4 : la base n'écoute que sur 127.0.0.1.
{
  const admin = new pgLib.Client({ host: '127.0.0.1', port, user: 'postgres', password, database: 'postgres' });
  await admin.connect();
  const exists = await admin.query(`SELECT 1 FROM pg_database WHERE datname = 'superapp'`);
  if (!exists.rowCount) await admin.query('CREATE DATABASE superapp');
  await admin.end();
}
console.log(`Base de données prête (${dataDir})`);

process.env.DATABASE_URL = `postgres://postgres:${encodeURIComponent(password)}@127.0.0.1:${port}/superapp`;
const { main } = await import('./server.js');
await main(async () => { await stopDb(); console.log('Base de données arrêtée proprement.'); });
