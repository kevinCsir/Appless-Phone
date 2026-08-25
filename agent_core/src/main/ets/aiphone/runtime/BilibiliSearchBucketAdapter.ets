import { aggregateMediaCandidates, aggregateVideoSourceBatchFromDynamicResults } from './AggregateSearchClient';
import { AggregateSearchSourceBatch } from './AggregateSearchTypes';
import { callBilibiliVideoSearch } from './BilibiliApiClient';
import {
  FeedChannelAvailabilityHook,
  FeedChannelAvailabilityListener,
  FeedChannelPhase,
  FeedChannelSnapshot,
  SearchRoundCompletionListener,
  SearchFeedChannelAdapter
} from './FeedChannelAdapter';
import { DynamicGenericToolResult } from './DynamicToolTypes';
import { WaterfallCandidate, WaterfallContinuation } from './WaterfallAnythingCore';

export type BilibiliSearchPageLoader = (
  query: string,
  page: number
) => Promise<DynamicGenericToolResult[]>;

export interface BilibiliSearchBucketOptions {
  /** Refill starts when the bucket falls below this size. Defaults to 10. */
  refillThreshold?: number;
  /** Each search page contributes at most this many candidates. Defaults to 10. */
  fetchBatchSize?: number;
  /** @deprecated Use refillThreshold. */
  lowWatermark?: number;
  /** @deprecated Use refillThreshold. */
  targetWatermark?: number;
  /** @deprecated Use fetchBatchSize. */
  pageSize?: number;
  loadPage?: BilibiliSearchPageLoader;
  availabilityHook?: FeedChannelAvailabilityHook;
  log?: (message: string) => void;
}

interface BilibiliKeywordSlot {
  query: string;
  continuation: WaterfallContinuation | null;
  terminal: boolean;
}

function boundedPositive(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback;
  return Math.max(1, Math.floor(value));
}

function normalizedQueries(value: string | string[]): string[] {
  const source = typeof value === 'string' ? [value] : value;
  const queries: string[] = [];
  source.forEach((query: string): void => {
    const normalized = query.trim();
    if (normalized.length > 0 && queries.indexOf(normalized) < 0) queries.push(normalized);
  });
  return queries;
}

export class BilibiliSearchBucketAdapter implements SearchFeedChannelAdapter {
  readonly id: string = 'bilibili:search';
  readonly platformId: string = 'bilibili';
  readonly kind: 'search' = 'search';

  private readonly lowWatermark: number;
  private readonly targetWatermark: number;
  private readonly pageSize: number;
  private readonly loadPage: BilibiliSearchPageLoader;
  private readonly availabilityHook: FeedChannelAvailabilityHook | null;
  private readonly log: ((message: string) => void) | null;
  private readonly items: WaterfallCandidate[] = [];
  private readonly seenIds: Set<string> = new Set<string>();
  private readonly seenUrls: Set<string> = new Set<string>();
  private availabilityListener: FeedChannelAvailabilityListener | null = null;
  private keywordRoundCompletionListener: SearchRoundCompletionListener | null = null;
  private query: string;
  private readonly keywordSlots: BilibiliKeywordSlot[] = [];
  private continuation: WaterfallContinuation | null = null;
  private phase: FeedChannelPhase = 'idle';
  private message: string = '';
  private generation: number = 0;
  private loadingGeneration: number = -1;
  private batchIndex: number = 0;
  private requestSequence: number = 0;
  private roundPending: number = 0;
  private blocked: boolean = false;
  private closed: boolean = false;

  constructor(query: string | string[], options: BilibiliSearchBucketOptions = {}) {
    const queries = normalizedQueries(query);
    this.query = queries.length > 0 ? queries[0] : '';
    queries.forEach((keyword: string): void => {
      this.keywordSlots.push({ query: keyword, continuation: null, terminal: false });
    });
    this.lowWatermark = boundedPositive(
      options.refillThreshold ?? options.lowWatermark,
      10
    );
    this.pageSize = boundedPositive(options.fetchBatchSize ?? options.pageSize, 10);
    this.targetWatermark = this.lowWatermark;
    this.loadPage = options.loadPage ?? callBilibiliVideoSearch;
    this.availabilityHook = options.availabilityHook ?? null;
    this.log = options.log ?? null;
    this.logState('constructed');
    this.ensureWatermark();
  }

  tryTake(): WaterfallCandidate | null {
    if (this.closed) return null;
    const before = this.items.length;
    const item = this.items.length > 0 ? this.items.shift() as WaterfallCandidate : null;
    this.logState(item === null ? 'take_empty' : 'take', 0,
      'before=' + before.toString() +
      (item === null ? '' : ' candidate=' + item.id + ' source=' + item.source));
    if (this.items.length < this.effectiveLowWatermark()) this.ensureWatermark();
    return item;
  }

  ensureWatermark(): void {
    if (this.closed || this.blocked || this.keywordSlots.length === 0 ||
      this.items.length >= this.effectiveLowWatermark() || this.roundPending > 0 ||
      this.phase === 'exhausted') return;
    const requestGeneration = this.generation;
    this.loadingGeneration = requestGeneration;
    const active = this.keywordSlots.filter((slot: BilibiliKeywordSlot): boolean => !slot.terminal);
    if (active.length === 0) {
      this.phase = this.items.length > 0 ? 'ready' : 'exhausted';
      this.loadingGeneration = -1;
      return;
    }
    this.roundPending = active.length;
    if (this.items.length === 0) this.phase = 'loading';
    this.message = '';
    this.logState('keyword_round_started', 0, 'requests=' + active.length.toString());
    active.forEach((slot: BilibiliKeywordSlot): void => {
      void this.refillKeyword(slot, requestGeneration);
    });
  }

  replaceQuery(query: string): void {
    this.replaceQueries([query]);
  }

  replaceQueries(queries: string[]): void {
    const next = normalizedQueries(queries);
    if (this.closed || next.length === 0 || next.join('\n') ===
      this.keywordSlots.map((slot: BilibiliKeywordSlot): string => slot.query).join('\n')) return;
    this.query = next[0];
    this.keywordSlots.splice(0, this.keywordSlots.length);
    next.forEach((keyword: string): void => {
      this.keywordSlots.push({ query: keyword, continuation: null, terminal: false });
    });
    this.resetSearchRequestState();
    this.ensureWatermark();
  }

  isKeywordRoundComplete(): boolean {
    return !this.closed && !this.blocked && this.keywordSlots.length > 0 && this.roundPending === 0 &&
      this.keywordSlots.every((slot: BilibiliKeywordSlot): boolean => slot.terminal);
  }

  setKeywordRoundCompletionListener(listener: SearchRoundCompletionListener | null): void {
    this.keywordRoundCompletionListener = listener;
  }

  setBlocked(blocked: boolean): void {
    if (this.closed || this.blocked === blocked) return;
    this.blocked = blocked;
    this.resetRecallState();
    this.loadingGeneration = -1;
    this.logState(blocked ? 'blocked' : 'unblocked');
    if (!blocked) this.ensureWatermark();
  }

  refresh(): void {
    if (this.closed) return;
    this.resetRecallState();
    this.ensureWatermark();
  }

  setAvailabilityListener(listener: FeedChannelAvailabilityListener | null): void {
    this.availabilityListener = listener;
  }

  snapshot(): FeedChannelSnapshot {
    return {
      id: this.id,
      platformId: this.platformId,
      kind: this.kind,
      phase: this.closed ? 'closed' : this.phase,
      size: this.items.length,
      lowWatermark: this.effectiveLowWatermark(),
      targetWatermark: this.effectiveLowWatermark(),
      continuation: this.continuation,
      query: this.query,
      queries: this.keywordSlots.map((slot: BilibiliKeywordSlot): string => slot.query),
      generation: this.generation,
      message: this.message
    };
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.generation++;
    this.items.splice(0, this.items.length);
    this.continuation = null;
    this.loadingGeneration = -1;
    this.roundPending = 0;
    this.phase = 'closed';
    this.availabilityListener = null;
  }

  private resetRecallState(): void {
    this.generation++;
    this.items.splice(0, this.items.length);
    this.continuation = null;
    this.phase = 'idle';
    this.message = '';
    this.batchIndex = 0;
    this.roundPending = 0;
    this.keywordSlots.forEach((slot: BilibiliKeywordSlot): void => {
      slot.continuation = null;
      slot.terminal = false;
    });
  }

  private resetSearchRequestState(): void {
    this.generation++;
    this.continuation = null;
    this.phase = this.items.length > 0 ? 'ready' : 'idle';
    this.message = '';
    this.batchIndex = 0;
    this.roundPending = 0;
    this.keywordSlots.forEach((slot: BilibiliKeywordSlot): void => {
      slot.continuation = null;
      slot.terminal = false;
    });
  }

  private effectiveLowWatermark(): number {
    return this.lowWatermark * Math.max(1, this.keywordSlots.length);
  }

  private currentPage(): number {
    if (this.continuation === null || this.continuation.kind !== 'page') return 1;
    const value = Number(this.continuation.value);
    return Number.isFinite(value) ? Math.max(1, Math.floor(value)) : 1;
  }

  private keywordPage(slot: BilibiliKeywordSlot): number {
    if (slot.continuation === null || slot.continuation.kind !== 'page') return 1;
    const value = Number(slot.continuation.value);
    return Number.isFinite(value) ? Math.max(1, Math.floor(value)) : 1;
  }

  private async refillKeyword(slot: BilibiliKeywordSlot, requestGeneration: number): Promise<void> {
    const requestId = this.id + '-' + (++this.requestSequence).toString();
    const startedAt = Date.now();
    try {
      const page = this.keywordPage(slot);
      this.logState('request_started', 0, 'requestId=' + requestId +
        ' keyword=' + JSON.stringify(slot.query) + ' page=' + page.toString());
      const previous: WaterfallContinuation | null = page > 1 ?
        { kind: 'page', value: page.toString() } : null;
      const dynamic = await this.loadPage(slot.query, page);
      if (this.closed || requestGeneration !== this.generation) return;
      const batch = aggregateVideoSourceBatchFromDynamicResults(
        'bilibili', dynamic, previous, this.pageSize);
      const added = this.enqueueBatch(batch, slot.query);
      slot.continuation = batch.continuation;
      slot.terminal = batch.continuation === null || batch.status.status === 'error' ||
        batch.status.status === 'needs_auth';
      this.message = batch.status.message;
      if (this.items.length > 0) this.phase = 'ready';
      this.logState('request_finished', added, 'requestId=' + requestId +
        ' keyword=' + JSON.stringify(slot.query) + ' page=' + page.toString() +
        ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' received=' + dynamic.length.toString() + ' added=' + added.toString() +
        ' terminal=' + (slot.terminal ? 'true' : 'false'));
    } catch (error) {
      if (requestGeneration !== this.generation || this.closed) return;
      slot.terminal = true;
      this.message = error instanceof Error ? error.message : 'Bilibili search refill failed.';
      this.logState('request_failed', 0, 'requestId=' + requestId +
        ' keyword=' + JSON.stringify(slot.query) +
        ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' error=' + this.message.substring(0, 160));
    } finally {
      if (!this.closed && requestGeneration === this.generation) this.finishKeywordRequest(requestGeneration);
    }
  }

  private finishKeywordRequest(requestGeneration: number): void {
    this.roundPending = Math.max(0, this.roundPending - 1);
    if (this.roundPending > 0) return;
    if (this.loadingGeneration === requestGeneration) this.loadingGeneration = -1;
    const hasActive = this.keywordSlots.some((slot: BilibiliKeywordSlot): boolean => !slot.terminal);
    this.phase = this.items.length > 0 ? 'ready' : (hasActive ? 'empty' : 'exhausted');
    this.logState('keyword_round_finished', 0, 'active=' + (hasActive ? 'true' : 'false'));
    if (!hasActive && this.keywordRoundCompletionListener !== null) {
      this.keywordRoundCompletionListener(this.id);
    }
    if (hasActive && this.items.length < this.effectiveLowWatermark()) this.ensureWatermark();
  }

  private async refill(requestGeneration: number): Promise<void> {
    const requestId = this.id + '-' + (++this.requestSequence).toString();
    const startedAt = Date.now();
    try {
      const page = this.currentPage();
      this.logState('request_started', 0, 'requestId=' + requestId + ' page=' + page.toString());
      const previous: WaterfallContinuation | null = page > 1 ?
        { kind: 'page', value: page.toString() } : null;
      const dynamic = await this.loadPage(this.query, page);
      if (this.closed || requestGeneration !== this.generation) return;
      const batch = aggregateVideoSourceBatchFromDynamicResults(
        'bilibili', dynamic, previous, this.pageSize);
      const added = this.enqueueBatch(batch, this.query);
      this.message = batch.status.message;
      this.logState('refill_complete', added);
      this.logState('request_finished', 0, 'requestId=' + requestId +
        ' page=' + page.toString() + ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' received=' + dynamic.length.toString() + ' added=' + added.toString());
      this.continuation = batch.continuation;
      if (batch.status.status === 'error' || batch.status.status === 'needs_auth') {
        this.phase = 'error';
        return;
      }
      if (this.continuation === null) {
        this.phase = this.items.length > 0 ? 'ready' :
          (batch.status.status === 'empty' ? 'empty' : 'exhausted');
        return;
      }
      this.phase = this.items.length > 0 ? 'ready' : 'empty';
    } catch (error) {
      if (requestGeneration !== this.generation || this.closed) return;
      this.phase = 'error';
      this.message = error instanceof Error ? error.message : 'Bilibili search refill failed.';
      this.logState('request_failed', 0, 'requestId=' + requestId +
        ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' error=' + this.message.substring(0, 160));
    } finally {
      if (this.loadingGeneration === requestGeneration) this.loadingGeneration = -1;
    }
  }

  private enqueueBatch(batch: AggregateSearchSourceBatch, query: string): number {
    const wasEmpty = this.items.length === 0;
    const candidates = aggregateMediaCandidates(
      batch.videos,
      batch.posts,
      this.batchIndex++,
      query,
      'original',
      'search',
      1
    );
    let added = 0;
    candidates.forEach((candidate: WaterfallCandidate): void => {
      const seenId = candidate.id.length > 0 && this.seenIds.has(candidate.id);
      const seenUrl = candidate.url.length > 0 && this.seenUrls.has(candidate.url);
      if (seenId || seenUrl) return;
      if (candidate.id.length > 0) this.seenIds.add(candidate.id);
      if (candidate.url.length > 0) this.seenUrls.add(candidate.url);
      this.items.push(candidate);
      added++;
    });
    if (wasEmpty && this.items.length > 0) {
      if (this.availabilityHook !== null) {
        try {
          this.availabilityHook.onFeedChannelAvailable(this.id);
        } catch (_error) {}
      }
      if (this.availabilityListener !== null) {
        try {
          this.availabilityListener();
        } catch (_error) {}
      }
    }
    return added;
  }

  private logState(event: string, added: number = 0, detail: string = ''): void {
    if (this.log === null) return;
    this.log('[FeedChannelAdapter] event=' + event + ' id=' + this.id +
      ' query=' + JSON.stringify(this.query) +
      ' size=' + this.items.length.toString() +
      ' added=' + added.toString() +
      ' queries=' + JSON.stringify(this.keywordSlots.map((slot: BilibiliKeywordSlot): string => slot.query)) +
      ' threshold=' + this.effectiveLowWatermark().toString() +
      ' batch=' + (this.pageSize * Math.max(1, this.keywordSlots.length)).toString() +
      ' generation=' + this.generation.toString() +
      (detail.length > 0 ? ' ' + detail : ''));
  }
}
