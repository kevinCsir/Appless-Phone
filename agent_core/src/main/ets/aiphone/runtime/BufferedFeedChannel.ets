import {
  FeedChannel,
  FeedChannelAvailabilityHook,
  FeedChannelAvailabilityListener,
  FeedChannelKind,
  FeedChannelPhase,
  FeedChannelSnapshot,
  RecommendFeedChannel,
  SearchRoundCompletionListener,
  SearchFeedChannel
} from './FeedChannelAdapter';
import { FeedSourceAdapter, FeedSourcePage } from './FeedSourceAdapter';
import {
  WaterfallCandidate,
  WaterfallContinuation
} from './WaterfallAnythingCore';

export interface BufferedFeedChannelOptions {
  refillThreshold?: number;
  fetchBatchSize?: number;
  availabilityHook?: FeedChannelAvailabilityHook;
  log?: (message: string) => void;
  maxConcurrentRequests?: number;
  parallelPageMode?: boolean;
}

interface SearchKeywordSlot {
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

abstract class BufferedFeedChannelBase implements FeedChannel {
  readonly id: string;
  readonly platformId: string;

  protected readonly channelKind: FeedChannelKind;
  private readonly sourceAdapter: FeedSourceAdapter;
  private readonly refillThreshold: number;
  private readonly fetchBatchSize: number;
  private readonly availabilityHook: FeedChannelAvailabilityHook | null;
  private readonly log: ((message: string) => void) | null;
  private readonly maxConcurrentRequests: number;
  private readonly parallelPageMode: boolean;
  private readonly items: WaterfallCandidate[] = [];
  private readonly seenIds: Set<string> = new Set<string>();
  private readonly seenUrls: Set<string> = new Set<string>();
  private availabilityListener: FeedChannelAvailabilityListener | null = null;
  private keywordRoundCompletionListener: SearchRoundCompletionListener | null = null;
  private query: string;
  private readonly searchSlots: SearchKeywordSlot[] = [];
  private continuation: WaterfallContinuation | null = null;
  private phase: FeedChannelPhase = 'idle';
  private message: string = '';
  private generation: number = 0;
  private loadingGeneration: number = -1;
  private parallelActiveRequests: number = 0;
  private parallelNextPageToSchedule: number = 0;
  private parallelHighestCompletedPage: number = -1;
  private parallelTerminal: boolean = false;
  private requestSequence: number = 0;
  private searchRoundPending: number = 0;
  private blocked: boolean = false;
  private closed: boolean = false;

  protected constructor(
    sourceAdapter: FeedSourceAdapter,
    query: string | string[],
    options: BufferedFeedChannelOptions
  ) {
    this.sourceAdapter = sourceAdapter;
    this.id = sourceAdapter.id;
    this.platformId = sourceAdapter.platformId;
    this.channelKind = sourceAdapter.kind;
    const queries = normalizedQueries(query);
    this.query = queries.length > 0 ? queries[0] : '';
    if (this.channelKind === 'search') {
      queries.forEach((keyword: string): void => {
        this.searchSlots.push({ query: keyword, continuation: null, terminal: false });
      });
    }
    this.refillThreshold = boundedPositive(options.refillThreshold, 10);
    this.fetchBatchSize = boundedPositive(options.fetchBatchSize, 10);
    this.availabilityHook = options.availabilityHook ?? null;
    this.log = options.log ?? null;
    this.maxConcurrentRequests = boundedPositive(options.maxConcurrentRequests, 1);
    this.parallelPageMode = options.parallelPageMode === true && this.maxConcurrentRequests > 1;
    this.logState('constructed');
    this.ensureWatermark();
  }

  abstract readonly kind: FeedChannelKind;

  tryTake(): WaterfallCandidate | null {
    if (this.closed) return null;
    const before = this.items.length;
    const item = this.items.length > 0 ? this.items.shift() as WaterfallCandidate : null;
    this.logState(item === null ? 'take_empty' : 'take', 0,
      'before=' + before.toString() +
      (item === null ? '' : ' candidate=' + item.id + ' source=' + item.source));
    if (this.items.length < this.effectiveRefillThreshold()) this.ensureWatermark();
    return item;
  }

  ensureWatermark(urgency: number = 0): void {
    if (this.blocked) return;
    if (this.channelKind === 'search') {
      this.ensureSearchKeywordRound();
      return;
    }
    if (this.parallelPageMode) {
      this.ensureParallelPageWatermark(urgency);
      return;
    }
    if (this.closed || this.items.length >= this.refillThreshold ||
      this.loadingGeneration === this.generation || this.phase === 'exhausted') return;
    const requestGeneration = this.generation;
    this.loadingGeneration = requestGeneration;
    this.phase = 'loading';
    this.message = '';
    this.logState('refill_start');
    void this.refill(requestGeneration);
  }

  refresh(): void {
    if (this.closed) return;
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

  setAvailabilityListener(listener: FeedChannelAvailabilityListener | null): void {
    this.availabilityListener = listener;
  }

  snapshot(): FeedChannelSnapshot {
    return {
      id: this.id,
      platformId: this.platformId,
      kind: this.channelKind,
      phase: this.closed ? 'closed' : this.phase,
      size: this.items.length,
      lowWatermark: this.effectiveRefillThreshold(),
      targetWatermark: this.effectiveRefillThreshold(),
      continuation: this.continuation,
      query: this.query,
      queries: this.searchSlots.map((slot: SearchKeywordSlot): string => slot.query),
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
    this.parallelActiveRequests = 0;
    this.searchRoundPending = 0;
    this.phase = 'closed';
    this.availabilityListener = null;
    this.logState('closed');
  }

  protected replaceStoredQuery(query: string): void {
    this.replaceStoredQueries([query]);
  }

  protected replaceStoredQueries(queries: string[]): void {
    const next = normalizedQueries(queries);
    if (this.closed || next.length === 0 || next.join('\n') ===
      this.searchSlots.map((slot: SearchKeywordSlot): string => slot.query).join('\n')) return;
    this.query = next[0];
    this.searchSlots.splice(0, this.searchSlots.length);
    next.forEach((keyword: string): void => {
      this.searchSlots.push({ query: keyword, continuation: null, terminal: false });
    });
    this.resetSearchRequestState();
    this.logState('queries_replaced');
    this.ensureWatermark();
  }

  isKeywordRoundComplete(): boolean {
    return !this.closed && !this.blocked && this.searchSlots.length > 0 && this.searchRoundPending === 0 &&
      this.searchSlots.every((slot: SearchKeywordSlot): boolean => slot.terminal);
  }

  setKeywordRoundCompletionListener(listener: SearchRoundCompletionListener | null): void {
    this.keywordRoundCompletionListener = listener;
  }

  private resetSearchRequestState(): void {
    this.generation++;
    this.continuation = null;
    this.phase = this.items.length > 0 ? 'ready' : 'idle';
    this.message = '';
    this.parallelActiveRequests = 0;
    this.parallelNextPageToSchedule = 0;
    this.parallelHighestCompletedPage = -1;
    this.parallelTerminal = false;
    this.searchRoundPending = 0;
    this.searchSlots.forEach((slot: SearchKeywordSlot): void => {
      slot.continuation = null;
      slot.terminal = false;
    });
  }

  private resetRecallState(): void {
    this.generation++;
    this.items.splice(0, this.items.length);
    this.continuation = null;
    this.phase = 'idle';
    this.message = '';
    this.parallelActiveRequests = 0;
    this.parallelNextPageToSchedule = 0;
    this.parallelHighestCompletedPage = -1;
    this.parallelTerminal = false;
    this.searchRoundPending = 0;
    this.searchSlots.forEach((slot: SearchKeywordSlot): void => {
      slot.continuation = null;
      slot.terminal = false;
    });
  }

  private effectiveRefillThreshold(): number {
    return this.refillThreshold * Math.max(1, this.searchSlots.length);
  }

  private ensureSearchKeywordRound(): void {
    if (this.closed || this.blocked || this.searchSlots.length === 0 ||
      this.items.length >= this.effectiveRefillThreshold() || this.searchRoundPending > 0) return;
    const active = this.searchSlots.filter((slot: SearchKeywordSlot): boolean => !slot.terminal);
    if (active.length === 0) {
      this.phase = this.items.length > 0 ? 'ready' : 'exhausted';
      return;
    }
    const requestGeneration = this.generation;
    this.loadingGeneration = requestGeneration;
    this.searchRoundPending = active.length;
    if (this.items.length === 0) this.phase = 'loading';
    this.message = '';
    this.logState('keyword_round_started', 0, 'requests=' + active.length.toString());
    active.forEach((slot: SearchKeywordSlot): void => {
      void this.runSearchKeywordRequest(slot, requestGeneration);
    });
  }

  private async runSearchKeywordRequest(
    slot: SearchKeywordSlot,
    requestGeneration: number
  ): Promise<void> {
    const requestId = this.id + '-' + (++this.requestSequence).toString();
    const startedAt = Date.now();
    this.logState('request_started', 0, 'requestId=' + requestId +
      ' keyword=' + JSON.stringify(slot.query) + ' continuation=' +
      (slot.continuation === null ? 'initial' : slot.continuation.kind + ':' + slot.continuation.value));
    try {
      const page = await this.sourceAdapter.load({
        query: slot.query,
        continuation: slot.continuation,
        limit: this.fetchBatchSize
      });
      if (this.closed || requestGeneration !== this.generation) return;
      const added = this.enqueue(page.candidates);
      slot.continuation = page.continuation;
      slot.terminal = page.continuation === null || page.phase === 'exhausted' || page.phase === 'error';
      this.message = page.message;
      if (this.items.length > 0) this.phase = 'ready';
      this.logState('request_finished', added, 'requestId=' + requestId +
        ' keyword=' + JSON.stringify(slot.query) +
        ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' received=' + page.candidates.length.toString() + ' added=' + added.toString() +
        ' terminal=' + (slot.terminal ? 'true' : 'false'));
    } catch (error) {
      if (this.closed || requestGeneration !== this.generation) return;
      slot.terminal = true;
      this.message = error instanceof Error ? error.message : 'Search keyword request failed.';
      this.logState('request_failed', 0, 'requestId=' + requestId +
        ' keyword=' + JSON.stringify(slot.query) +
        ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' error=' + this.message.substring(0, 160));
    } finally {
      if (!this.closed && requestGeneration === this.generation) this.finishSearchKeywordRequest(requestGeneration);
    }
  }

  private finishSearchKeywordRequest(requestGeneration: number): void {
    this.searchRoundPending = Math.max(0, this.searchRoundPending - 1);
    if (this.searchRoundPending > 0) return;
    if (this.loadingGeneration === requestGeneration) this.loadingGeneration = -1;
    const hasActive = this.searchSlots.some((slot: SearchKeywordSlot): boolean => !slot.terminal);
    this.phase = this.items.length > 0 ? 'ready' : (hasActive ? 'empty' : 'exhausted');
    this.logState('keyword_round_finished', 0, 'active=' + (hasActive ? 'true' : 'false'));
    if (!hasActive && this.keywordRoundCompletionListener !== null) {
      this.keywordRoundCompletionListener(this.id);
    }
    if (hasActive && this.items.length < this.effectiveRefillThreshold()) this.ensureWatermark();
  }

  private ensureParallelPageWatermark(urgency: number): void {
    if (this.closed || this.blocked || this.query.length === 0 || this.parallelTerminal ||
      this.items.length >= this.refillThreshold) return;
    const desired = urgency >= this.refillThreshold * 2 ? this.maxConcurrentRequests : 1;
    while (this.parallelActiveRequests < desired) {
      this.startParallelPageRequest(this.parallelNextPageToSchedule++);
    }
  }

  private startParallelPageRequest(page: number): void {
    const requestGeneration = this.generation;
    const requestId = this.id + '-' + (++this.requestSequence).toString();
    const startedAt = Date.now();
    const continuation: WaterfallContinuation | null = page === 0 ? null :
      { kind: 'page', value: page.toString() };
    this.parallelActiveRequests++;
    if (this.items.length === 0) this.phase = 'loading';
    this.logState('request_started', 0, 'requestId=' + requestId +
      ' page=' + page.toString() + ' concurrency=' + this.parallelActiveRequests.toString());
    void this.sourceAdapter.load({
      query: this.query,
      continuation,
      limit: this.fetchBatchSize
    }).then((result: FeedSourcePage): void => {
      if (this.closed || requestGeneration !== this.generation) return;
      this.parallelActiveRequests--;
      const added = this.enqueue(result.candidates);
      if (page > this.parallelHighestCompletedPage) {
        this.parallelHighestCompletedPage = page;
        this.continuation = result.continuation;
      }
      this.message = result.message;
      if (result.continuation === null || result.phase === 'exhausted') this.parallelTerminal = true;
      if (this.items.length > 0) this.phase = 'ready';
      else if (this.parallelTerminal) this.phase = 'exhausted';
      else if (this.parallelActiveRequests > 0) this.phase = 'loading';
      else this.phase = result.phase;
      this.logState('request_finished', added, 'requestId=' + requestId +
        ' page=' + page.toString() + ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' received=' + result.candidates.length.toString() + ' added=' + added.toString() +
        ' phase=' + result.phase);
      this.ensureParallelPageWatermark(0);
    }).catch((error: Error): void => {
      if (this.closed || requestGeneration !== this.generation) return;
      this.parallelActiveRequests--;
      this.phase = 'error';
      this.message = error.message;
      this.logState('request_failed', 0, 'requestId=' + requestId +
        ' page=' + page.toString() + ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' error=' + error.message.substring(0, 160));
    });
  }

  private async refill(requestGeneration: number): Promise<void> {
    const requestId = this.id + '-' + (++this.requestSequence).toString();
    const startedAt = Date.now();
    this.logState('request_started', 0, 'requestId=' + requestId +
      ' continuation=' + (this.continuation === null ? 'initial' :
        this.continuation.kind + ':' + this.continuation.value));
    try {
      const page = await this.sourceAdapter.load({
        query: this.query,
        continuation: this.continuation,
        limit: this.fetchBatchSize
      });
      if (this.closed || requestGeneration !== this.generation) return;
      const added = this.enqueue(page.candidates);
      this.continuation = page.continuation;
      this.message = page.message;
      this.phase = page.phase === 'ready' && this.items.length === 0 ? 'empty' : page.phase;
      this.logState('refill_complete', added);
      this.logState('request_finished', 0, 'requestId=' + requestId +
        ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' received=' + page.candidates.length.toString() + ' added=' + added.toString());
    } catch (error) {
      if (requestGeneration !== this.generation || this.closed) return;
      this.phase = 'error';
      this.message = error instanceof Error ? error.message : 'Feed channel refill failed.';
      this.logState('refill_failed');
      this.logState('request_failed', 0, 'requestId=' + requestId +
        ' elapsedMs=' + (Date.now() - startedAt).toString() +
        ' error=' + this.message.substring(0, 160));
    } finally {
      if (this.loadingGeneration === requestGeneration) this.loadingGeneration = -1;
    }
  }

  private enqueue(candidates: WaterfallCandidate[]): number {
    const wasEmpty = this.items.length === 0;
    let added = 0;
    const limit = Math.min(candidates.length, this.fetchBatchSize);
    for (let index = 0; index < limit; index++) {
      const candidate = candidates[index];
      const seenId = candidate.id.length > 0 && this.seenIds.has(candidate.id);
      const seenUrl = candidate.url.length > 0 && this.seenUrls.has(candidate.url);
      if (seenId || seenUrl) continue;
      if (candidate.id.length > 0) this.seenIds.add(candidate.id);
      if (candidate.url.length > 0) this.seenUrls.add(candidate.url);
      this.items.push(candidate);
      added++;
    }
    if (wasEmpty && this.items.length > 0) this.notifyAvailable();
    return added;
  }

  private notifyAvailable(): void {
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

  private logState(event: string, added: number = 0, detail: string = ''): void {
    if (this.log === null) return;
    this.log('[BufferedFeedChannel] event=' + event +
      ' id=' + this.id +
      ' query=' + JSON.stringify(this.query) +
      ' queries=' + JSON.stringify(this.searchSlots.map((slot: SearchKeywordSlot): string => slot.query)) +
      ' size=' + this.items.length.toString() +
      ' added=' + added.toString() +
      ' threshold=' + this.effectiveRefillThreshold().toString() +
      ' batch=' + this.fetchBatchSize.toString() +
      ' generation=' + this.generation.toString() +
      (detail.length > 0 ? ' ' + detail : ''));
  }
}

export class BufferedSearchFeedChannel extends BufferedFeedChannelBase implements SearchFeedChannel {
  readonly kind: 'search' = 'search';

  constructor(
    sourceAdapter: FeedSourceAdapter,
    query: string | string[],
    options: BufferedFeedChannelOptions = {}
  ) {
    if (sourceAdapter.kind !== 'search') throw new Error(sourceAdapter.id + ' is not a search source.');
    super(sourceAdapter, query, options);
  }

  replaceQuery(query: string): void {
    this.replaceStoredQuery(query);
  }

  replaceQueries(queries: string[]): void {
    this.replaceStoredQueries(queries);
  }
}

export class BufferedRecommendFeedChannel extends BufferedFeedChannelBase
  implements RecommendFeedChannel {
  readonly kind: 'recommend' = 'recommend';

  constructor(
    sourceAdapter: FeedSourceAdapter,
    options: BufferedFeedChannelOptions = {}
  ) {
    if (sourceAdapter.kind !== 'recommend') throw new Error(sourceAdapter.id + ' is not a recommend source.');
    super(sourceAdapter, '', options);
  }
}
