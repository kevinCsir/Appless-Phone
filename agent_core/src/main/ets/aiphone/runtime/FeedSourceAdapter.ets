import { FeedChannelKind, FeedChannelPhase } from './FeedChannelAdapter';
import { WaterfallCandidate, WaterfallContinuation } from './WaterfallAnythingCore';

/** A single stateless-looking page request. Platform pagination state stays opaque. */
export interface FeedSourceRequest {
  query: string;
  continuation: WaterfallContinuation | null;
  limit: number;
}

export interface FeedSourcePage {
  candidates: WaterfallCandidate[];
  continuation: WaterfallContinuation | null;
  phase: FeedChannelPhase;
  message: string;
}

/**
 * Minimal platform contract. Implementations may keep client/auth state, but do
 * not own buffering, watermarks, deduplication or keyword scheduling.
 */
export interface FeedSourceAdapter {
  readonly id: string;
  readonly platformId: string;
  readonly kind: FeedChannelKind;

  load(request: FeedSourceRequest): Promise<FeedSourcePage>;
}
