import { WaterfallCandidate, WaterfallContinuation } from './WaterfallAnythingCore';

export type FeedChannelKind = 'search' | 'recommend';
export type FeedChannelPhase = 'idle' | 'loading' | 'ready' | 'empty' | 'error' | 'exhausted' | 'closed';

export interface FeedChannelSnapshot {
  id: string;
  platformId: string;
  kind: FeedChannelKind;
  phase: FeedChannelPhase;
  size: number;
  lowWatermark: number;
  targetWatermark: number;
  continuation: WaterfallContinuation | null;
  query: string;
  generation: number;
  message: string;
}

export type FeedChannelAvailabilityListener = () => void;

/** Passed into adapters at construction so a pool can wake blocked get() calls. */
export interface FeedChannelAvailabilityHook {
  onFeedChannelAvailable(channelId: string): void;
}

/** A channel owns a local non-blocking bucket and maintains its own water level. */
export interface FeedChannelAdapter {
  readonly id: string;
  readonly platformId: string;
  readonly kind: FeedChannelKind;

  tryTake(): WaterfallCandidate | null;
  ensureWatermark(urgency?: number): void;
  refresh(): void;
  setAvailabilityListener(listener: FeedChannelAvailabilityListener | null): void;
  snapshot(): FeedChannelSnapshot;
  close(): void;
}

export interface SearchFeedChannelAdapter extends FeedChannelAdapter {
  readonly kind: 'search';
  replaceQuery(query: string): void;
}

export interface RecommendFeedChannelAdapter extends FeedChannelAdapter {
  readonly kind: 'recommend';
}
