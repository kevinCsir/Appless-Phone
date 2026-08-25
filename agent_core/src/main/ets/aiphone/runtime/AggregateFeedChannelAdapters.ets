import { aggregateMediaCandidates } from './AggregateSearchClient';
import { aggregateSearchSearchSourceIds } from './AggregateSearchSourceRegistry';
import {
  AggregateSearchSource,
  AggregateSearchSourceBatch
} from './AggregateSearchTypes';
import {
  FeedChannelAdapter,
  FeedChannelAvailabilityHook,
  FeedChannelAvailabilityListener,
  FeedChannelKind,
  FeedChannelPhase,
  FeedChannelSnapshot,
  RecommendFeedChannelAdapter,
  SearchRoundCompletionListener,
  SearchFeedChannelAdapter
} from './FeedChannelAdapter';
import {
  callConfiguredAggregateSearchContinuation,
  callConfiguredWaterfallInterestRecall,
  WaterfallInterestRecallBatch
} from './ToolGatewayClient';
import {
  WaterfallCandidate,
  WaterfallContinuation,
  WaterfallInterestRecallRequest,
  WaterfallLoadRequest
} from './WaterfallAnythingCore';

export interface AggregateFeedChannelLoadRequest {
  source: AggregateSearchSource;
  kind: FeedChannelKind;
  query: string;
  continuation: WaterfallContinuation | null;
  limit: number;
}

export interface AggregateFeedChannelPage {
  candidates: WaterfallCandidate[];
  continuation: WaterfallContinuation | null;
  phase: FeedChannelPhase;
  message: string;
}

export type AggregateFeedChannelPageLoader = (
  request: AggregateFeedChannelLoadRequest
) => Promise<AggregateFeedChannelPage>;

export interface AggregateFeedBucketOptions {
  refillThreshold?: number;
  fetchBatchSize?: number;
  loadPage?: AggregateFeedChannelPageLoader;
  availabilityHook?: FeedChannelAvailabilityHook;
  log?: (message: string) => void;
  maxConcurrentRequests?: number;
}

interface AggregateSearchKeywordSlot {
  query: string;
  continuation: WaterfallContinuation | null;
  terminal: boolean;
}

class AggregateBatchHolder {
  value: AggregateSearchSourceBatch | null = null;
}

class InterestBatchHolder {
  value: WaterfallInterestRecallBatch | null = null;
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

function phaseFromBatch(batch: AggregateSearchSourceBatch): FeedChannelPhase {
  if (batch.status.status === 'error' || batch.status.status === 'needs_auth') return 'error';
  if (batch.status.status === 'unsupported') return 'exhausted';
  if (batch.videos.length + batch.posts.length === 0) {
    return batch.continuation === null ? 'exhausted' : 'empty';
  }
  return 'ready';
}

export async function loadAggregateSearchFeedPage(
  request: AggregateFeedChannelLoadRequest
): Promise<AggregateFeedChannelPage> {
  const holder = new AggregateBatchHolder();
  const load: WaterfallLoadRequest = {
    source: request.source,
    continuation: request.continuation,
    limit: request.limit,
    phase: 'loading',
    message: '',
    mode: 'search',
    query: request.query,
    route: 'explore'
  };
  await callConfiguredAggregateSearchContinuation(
    request.query,
    [load],
    (batch: AggregateSearchSourceBatch): void => {
      holder.value = batch;
    }
  );
  const batch = holder.value;
  if (batch === null) {
    return {
      candidates: [],
      continuation: null,
      phase: 'error',
      message: 'No aggregate search batch returned for ' + request.source + '.'
    };
  }
  return {
    candidates: aggregateMediaCandidates(
      batch.videos,
      batch.posts,
      0,
      request.query,
      'original',
      'search',
      1
    ),
    continuation: batch.continuation,
    phase: phaseFromBatch(batch),
    message: batch.status.message
  };
}

export async function loadAggregateRecommendFeedPage(
  request: AggregateFeedChannelLoadRequest
): Promise<AggregateFeedChannelPage> {
  const holder = new InterestBatchHolder();
  const recall: WaterfallInterestRecallRequest = {
    route: request.source === 'youtube' ? 'popular' : 'explore',
    query: '',
    sources: [request.source],
    weight: 1,
    continuation: request.continuation
  };
  await callConfiguredWaterfallInterestRecall(
    [recall],
    (result: WaterfallInterestRecallBatch): void => {
      holder.value = result;
    }
  );
  const result = holder.value;
  if (result === null) {
    return {
      candidates: [],
      continuation: null,
      phase: 'error',
      message: 'No recommendation batch returned for ' + request.source + '.'
    };
  }
  return {
    candidates: result.candidates,
    continuation: result.batch.continuation,
    phase: request.source === 'zhihu' ? 'exhausted' : phaseFromBatch(result.batch),
    message: result.batch.status.message
  };
}

abstract class AggregateFeedBucketBase implements FeedChannelAdapter {
  readonly id: string;
  readonly platformId: string;

  protected readonly channelKind: FeedChannelKind;
  private readonly refillThreshold: number;
  private readonly fetchBatchSize: number;
  private readonly loadPage: AggregateFeedChannelPageLoader;
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
  private readonly searchSlots: AggregateSearchKeywordSlot[] = [];
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
    source: AggregateSearchSource,
    kind: FeedChannelKind,
    query: string | string[],
    options: AggregateFeedBucketOptions
  ) {
    this.id = source + ':' + kind;
    this.platformId = source;
    this.channelKind = kind;
    const queries = normalizedQueries(query);
    this.query = queries.length > 0 ? queries[0] : '';
    if (kind === 'search') {
      queries.forEach((keyword: string): void => {
        this.searchSlots.push({ query: keyword, continuation: null, terminal: false });
      });
    }
    this.refillThreshold = boundedPositive(options.refillThreshold, 10);
    this.fetchBatchSize = boundedPositive(options.fetchBatchSize, 10);
    this.loadPage = options.loadPage ??
      (kind === 'search' ? loadAggregateSearchFeedPage : loadAggregateRecommendFeedPage);
    this.availabilityHook = options.availabilityHook ?? null;
    this.log = options.log ?? null;
    this.maxConcurrentRequests = boundedPositive(options.maxConcurrentRequests, 1);
    this.parallelPageMode = source === 'hackernews' && kind === 'search' && this.maxConcurrentRequests > 1;
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
      queries: this.searchSlots.map((slot: AggregateSearchKeywordSlot): string => slot.query),
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
      this.searchSlots.map((slot: AggregateSearchKeywordSlot): string => slot.query).join('\n')) return;
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
      this.searchSlots.every((slot: AggregateSearchKeywordSlot): boolean => slot.terminal);
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
    this.searchSlots.forEach((slot: AggregateSearchKeywordSlot): void => {
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
    this.searchSlots.forEach((slot: AggregateSearchKeywordSlot): void => {
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
    const active = this.searchSlots.filter((slot: AggregateSearchKeywordSlot): boolean => !slot.terminal);
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
    active.forEach((slot: AggregateSearchKeywordSlot): void => {
      void this.runSearchKeywordRequest(slot, requestGeneration);
    });
  }

  private async runSearchKeywordRequest(
    slot: AggregateSearchKeywordSlot,
    requestGeneration: number
  ): Promise<void> {
    const requestId = this.id + '-' + (++this.requestSequence).toString();
    const startedAt = Date.now();
    this.logState('request_started', 0, 'requestId=' + requestId +
      ' keyword=' + JSON.stringify(slot.query) + ' continuation=' +
      (slot.continuation === null ? 'initial' : slot.continuation.kind + ':' + slot.continuation.value));
    try {
      const page = await this.loadPage({
        source: this.platformId as AggregateSearchSource,
        kind: this.channelKind,
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
    const hasActive = this.searchSlots.some((slot: AggregateSearchKeywordSlot): boolean => !slot.terminal);
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
    void this.loadPage({
      source: this.platformId as AggregateSearchSource,
      kind: this.channelKind,
      query: this.query,
      continuation,
      limit: this.fetchBatchSize
    }).then((result: AggregateFeedChannelPage): void => {
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
      const page = await this.loadPage({
        source: this.platformId as AggregateSearchSource,
        kind: this.channelKind,
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
    this.log('[FeedChannelAdapter] event=' + event +
      ' id=' + this.id +
      ' query=' + JSON.stringify(this.query) +
      ' queries=' + JSON.stringify(this.searchSlots.map((slot: AggregateSearchKeywordSlot): string => slot.query)) +
      ' size=' + this.items.length.toString() +
      ' added=' + added.toString() +
      ' threshold=' + this.effectiveRefillThreshold().toString() +
      ' batch=' + this.fetchBatchSize.toString() +
      ' generation=' + this.generation.toString() +
      (detail.length > 0 ? ' ' + detail : ''));
  }
}

export class AggregateSearchBucketAdapter extends AggregateFeedBucketBase implements SearchFeedChannelAdapter {
  readonly kind: 'search' = 'search';

  constructor(
    source: AggregateSearchSource,
    query: string | string[],
    options: AggregateFeedBucketOptions = {}
  ) {
    if (aggregateSearchSearchSourceIds().indexOf(source) < 0) {
      throw new Error(source + ' does not support aggregate search.');
    }
    super(source, 'search', query, options);
  }

  replaceQuery(query: string): void {
    this.replaceStoredQuery(query);
  }

  replaceQueries(queries: string[]): void {
    this.replaceStoredQueries(queries);
  }
}

export class AggregateRecommendBucketAdapter extends AggregateFeedBucketBase
  implements RecommendFeedChannelAdapter {
  readonly kind: 'recommend' = 'recommend';

  constructor(
    source: AggregateSearchSource,
    options: AggregateFeedBucketOptions = {}
  ) {
    if (source !== 'youtube' && source !== 'twitch' && source !== 'zhihu') {
      throw new Error(source + ' does not expose a keyword-free recommendation channel.');
    }
    super(source, 'recommend', '', options);
  }
}

export function aggregateSearchAdapterSources(): AggregateSearchSource[] {
  return aggregateSearchSearchSourceIds();
}

export function aggregateRecommendAdapterSources(): AggregateSearchSource[] {
  return ['youtube', 'zhihu', 'twitch'];
}
