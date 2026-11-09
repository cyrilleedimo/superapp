// Comparateur de voyages. Les prix de vols/hôtels ne peuvent PAS être inventés :
// ils viennent d'un partenaire de données sous contrat ([TRAVEL API PARTNER]).
// Tant qu'aucun partenaire n'est branché, l'API répond 503 travel_not_configured.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { AppError, parse } from '../../lib/errors.js';

export interface FlightOffer {
  carrier: string; departAt: string; arriveAt: string; durationMin: number; stops: number;
  priceXaf: number; bookingUrl: string; source: string;
}

export interface TravelProvider {
  searchFlights(q: { from: string; to: string; departDate: string; returnDate?: string; adults: number }): Promise<FlightOffer[]>;
}

export async function travelRoutes(app: FastifyInstance, provider: TravelProvider | null) {
  app.get('/travel/flights', async (req) => {
    const q = parse(z.object({
      from: z.string().regex(/^[A-Z]{3}$/, 'code IATA, ex. DLA'),
      to: z.string().regex(/^[A-Z]{3}$/),
      departDate: z.iso.date(),
      returnDate: z.iso.date().optional(),
      adults: z.coerce.number().int().min(1).max(9).default(1),
    }), req.query);
    if (!provider) throw new AppError(503, 'travel_not_configured');
    const offers = await provider.searchFlights(q);
    return { items: offers.sort((a, b) => a.priceXaf - b.priceXaf) };
  });
}
