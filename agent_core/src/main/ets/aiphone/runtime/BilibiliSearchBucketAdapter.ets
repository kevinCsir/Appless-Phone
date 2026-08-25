import { aggregateMediaCandidates, aggregateVideoSourceBatchFromDynamicResults } from './AggregateSearchClient';
import { AggregateSearchSourceBatch } from './AggregateSearchTypes';
import { callBilibiliVideoSearch } from './BilibiliApiClient';
import {
  FeedChannelAvailabilityHook,
  FeedChannelAvailabilityListener,
  FeedChannelPhase,
  FeedChannelSnapshot,
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

function boundedPositive(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback;
  return Math.max(1, Math.floor(value));
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
  private query: string;
  private continuation: WaterfallContinuation | null = null;
  private phase: FeedChannelPhase = 'idle';
  private message: string = '';
  private generation: number = 0;
  private loadingGeneration: number = -1;
  private batchIndex: number = 0;
  private requestSequence: number = 0;
  private blocked: boolean = false;
  private closed: boolean = false;

  constructor(query: string, options: BilibiliSearchBucketOptions = {}) {
    this.query = query.trim();
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
    if (this.items.length < this.lowWatermark) this.ensureWatermark();
    return item;
  }

  ensureWatermark(): void {
    if (this.closed || this.blocked || this.query.length === 0 || this.items.length >= this.lowWatermark ||
      this.loadingGeneration === this.generation || this.phase === 'exhausted') return;
    const requestGeneration = this.generation;
    this.loadingGeneration = requestGeneration;
    this.phase = 'loading';
    this.message = '';
    this.logState('refill_start');
    void this.refill(requestGeneration);
  }

  replaceQuery(query: string): void {
    const next = query.trim();
    if (this.closed || next === this.query) return;
    this.query = next;
    this.resetRecallState();
    this.ensureWatermark();
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
      lowWatermark: this.lowWatermark,
      targetWatermark: this.targetWatermark,
      continuation: this.continuation,
      query: this.query,
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
  }

  private currentPage(): number {
    if (this.continuation === null || this.continuation.kind !== 'page') return 1;
    const value = Number(this.continuation.value);
    return Number.isFinite(value) ? Math.max(1, Math.floor(value)) : 1;
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
      const added = this.enqueueBatch(batch);
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

  private enqueueBatch(batch: AggregateSearchSourceBatch): number {
    const wasEmpty = this.items.length === 0;
    const candidates = aggregateMediaCandidates(
      batch.videos,
      batch.posts,
      this.batchIndex++,
      this.query,
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
      ' threshold=' + this.lowWatermark.toString() +
      ' batch=' + this.pageSize.toString() +
      ' generation=' + this.generation.toString() +
      (detail.length > 0 ? ' ' + detail : ''));
  }
}
