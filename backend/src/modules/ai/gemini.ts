// Client minimal pour Google AI Studio (Gemini), utilisé uniquement pour suggérer un
// titre + une description d'annonce à partir des photos envoyées par le vendeur.
// Doc : https://ai.google.dev/api/generate-content
// Volontairement strict : le modèle ne doit JAMAIS inventer un prix, un état, une marque
// ou une caractéristique qu'il ne peut pas voir sur la photo — c'est au vendeur de les
// confirmer. En cas de doute, il doit rester vague plutôt qu'affirmer quelque chose de faux.
export interface ListingSuggestion { title: string; description: string }

const PROMPT = `Tu regardes une ou plusieurs photos d'un article mis en vente sur une
marketplace de seconde main en Afrique (Cameroun). Rédige en français :
- "title" : un titre court et honnête (max 100 caractères), basé UNIQUEMENT sur ce qui est
  visible sur la photo.
- "description" : 2 à 4 phrases décrivant l'article (type d'objet, couleur, matière apparente,
  état visuel général). N'invente jamais une marque, un modèle, un prix ou un état que tu ne
  peux pas vérifier sur l'image ; si tu n'es pas sûr d'un détail, ne le mentionne pas plutôt
  que de l'affirmer. Ne mentionne jamais le prix (le vendeur le fixe lui-même).
Réponds uniquement avec un objet JSON {"title": "...", "description": "..."}, sans texte autour.`;

export async function suggestListingText(
  apiKey: string,
  model: string,
  images: { mime: string; base64: string }[],
): Promise<ListingSuggestion> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent?key=${encodeURIComponent(apiKey)}`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(20_000),
    body: JSON.stringify({
      contents: [{
        parts: [
          { text: PROMPT },
          ...images.map((img) => ({ inline_data: { mime_type: img.mime, data: img.base64 } })),
        ],
      }],
      generationConfig: { responseMimeType: 'application/json', maxOutputTokens: 300 },
    }),
  });
  const json = (await res.json().catch(() => ({}))) as Record<string, unknown>;
  if (!res.ok) throw new Error(`gemini: HTTP ${res.status} ${JSON.stringify(json).slice(0, 300)}`);

  const candidates = json.candidates as Array<{ content?: { parts?: Array<{ text?: string }> } }> | undefined;
  const text = candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error('gemini: réponse vide ou inattendue');

  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { throw new Error('gemini: réponse non-JSON'); }
  const { title, description } = parsed as { title?: unknown; description?: unknown };
  if (typeof title !== 'string' || typeof description !== 'string') throw new Error('gemini: champs manquants');
  return { title: title.slice(0, 120), description: description.slice(0, 4000) };
}
