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
  queries?: string[];
  generation: number;
  message: string;
}

export type FeedChannelAvailabilityListener = () => void;
export type SearchRoundCompletionListener = (channelId: string) => void;

/** Passed into adapters at construction so a pool can wake blocked get() calls. */
export interface FeedChannelAvailabilityHook {
  onFeedChannelAvailable(channelId: string): void;
}

/** A schedulable buffered channel. Platform I/O lives in FeedSourceAdapter. */
export interface FeedChannel {
  readonly id: string;
  readonly platformId: string;
  readonly kind: FeedChannelKind;

  tryTake(): WaterfallCandidate | null;
  ensureWatermark(urgency?: number): void;
  setBlocked(blocked: boolean): void;
  refresh(): void;
  setAvailabilityListener(listener: FeedChannelAvailabilityListener | null): void;
  snapshot(): FeedChannelSnapshot;
  close(): void;
}

export interface SearchFeedChannel extends FeedChannel {
  readonly kind: 'search';
  replaceQuery(query: string): void;
  replaceQueries(queries: string[]): void;
  isKeywordRoundComplete(): boolean;
  setKeywordRoundCompletionListener(listener: SearchRoundCompletionListener | null): void;
}

export interface RecommendFeedChannel extends FeedChannel {
  readonly kind: 'recommend';
}

/** @deprecated Use FeedChannel. */
export interface FeedChannelAdapter extends FeedChannel {}
/** @deprecated Use SearchFeedChannel. */
export interface SearchFeedChannelAdapter extends SearchFeedChannel {}
/** @deprecated Use RecommendFeedChannel. */
export interface RecommendFeedChannelAdapter extends RecommendFeedChannel {}
