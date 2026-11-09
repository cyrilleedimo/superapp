-- 003_user_exports.sql — Nom de fichier stable et unique de l'export lisible de chaque utilisateur.
CREATE TABLE user_export_files (
  user_id      uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  file_name    text NOT NULL,
  exported_at  timestamptz
);
-- Unicité insensible à la casse : Windows ne distingue pas « Paul.json » de « paul.json ».
CREATE UNIQUE INDEX user_export_files_name_idx ON user_export_files (lower(file_name));
