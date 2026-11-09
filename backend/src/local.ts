// Lanceur « serveur sur mon PC » : démarre une base PostgreSQL EMBARQUÉE (aucune
// installation système) dont les données vivent dans PG_DATA_DIR, puis l'API.
//   PG_DATA_DIR   ex. C:\Users\Paul\Desktop\Base de données\système
//   PG_PASSWORD   mot de passe généré à l'installation (dans .env)
//   PG_PORT       port local de la base (défaut 54329, jamais exposé sur Internet)
import { existsSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import EmbeddedPostgres from 'embedded-postgres';

const dataDir = process.env.PG_DATA_DIR;
const password = process.env.PG_PASSWORD;
const port = Number(process.env.PG_PORT ?? 54329);
if (!dataDir || !password) throw new Error('PG_DATA_DIR et PG_PASSWORD sont requis (voir .env)');

const pg = new EmbeddedPostgres({ databaseDir: dataDir, user: 'postgres', password, port, persistent: true, onLog: () => {} });

const firstRun = !existsSync(join(dataDir, 'PG_VERSION'));
if (firstRun) {
  console.log('Première exécution : création de la base de données…');
  mkdirSync(dirname(dataDir), { recursive: true }); // initdb ne crée que le dernier dossier
  await pg.initialise();
}
await pg.start();
if (firstRun) await pg.createDatabase('superapp');
console.log(`Base de données prête (${dataDir})`);

process.env.DATABASE_URL = `postgres://postgres:${encodeURIComponent(password)}@127.0.0.1:${port}/superapp`;
const { main } = await import('./server.js');
await main(async () => { await pg.stop(); console.log('Base de données arrêtée proprement.'); });
