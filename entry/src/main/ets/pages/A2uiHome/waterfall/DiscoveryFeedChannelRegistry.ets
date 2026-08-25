import {
  AggregateFeedSourceAdapter,
  AggregateSearchSource,
  BilibiliSearchSourceAdapter,
  BufferedRecommendFeedChannel,
  BufferedSearchFeedChannel,
  DiscoveryFeedReserve,
  DiscoveryFeedReserveSnapshot,
  FeedChannel,
  FeedChannelKind,
  SearchFeedChannel,
  WaterfallCandidate,
  WATERFALL_EXPLORATION_QUERIES,
  WaterfallPreferenceSnapshot,
  WaterfallRankedCandidate,
  WeightedFeedChannelPool,
  WeightedFeedChannelPoolSnapshot,
  aggregateRecommendAdapterSources,
  aggregateSearchAdapterSources,
  aiLogInfo
} from '@loop/agent-core';

const DEFAULT_DISCOVERY_QUERY: string = '人工智能';
const SEARCH_DELIVERIES_PER_KEYWORD: number = 40;
const DEFAULT_SEARCH_KEYWORD_BATCH_SIZE: number = 2;
const EMPTY_SEARCH_ROTATION_BASE_DELAY_MS: number = 15000;
const EMPTY_SEARCH_ROTATION_MAX_DELAY_MS: number = 300000;

export interface DiscoveryKeywordSnapshot {
  keyword: string;
  heat: number;
  lastUsedSequence: number;
  current: boolean;
}

interface DiscoveryKeywordState {
  keyword: string;
  heat: number;
  lastUsedSequence: number;
}

function discoveryFeedLog(message: string): void {
  aiLogInfo('[AIPhone][DiscoveryFeedChannel] ' + message);
}

export interface DiscoveryFeedChannelRegistrySnapshot extends WeightedFeedChannelPoolSnapshot {
  active: boolean;
  reserve: DiscoveryFeedReserveSnapshot | null;
  currentKeyword: string;
  currentKeywords: string[];
  currentKeywordDeliveries: number;
  keywordDeliveryLimit: number;
  keywords: DiscoveryKeywordSnapshot[];
  enabledSources: string[];
}

/**
 * Application-wide registry for discovery feed channels.
 *
 * Constructing the registry composes every source with a buffered channel, which immediately starts
 * its first 10-item prefetch. The weighted pool is the single blocking source
 * that the reserve layer can consume.
 */
export class DiscoveryFeedChannelRegistry {
  private readonly pool: WeightedFeedChannelPool;
  private reserve: DiscoveryFeedReserve | null = null;
  private readonly searchAdapters: SearchFeedChannel[] = [];
  private readonly adapters: FeedChannel[] = [];
  private readonly keywordQueue: DiscoveryKeywordState[] = [];
  private currentKeyword: DiscoveryKeywordState;
  private keywordUseSequence: number = 0;
  private currentKeywordDeliveries: number = 0;
  private readonly keywordBatchSize: number;
  private enabledSources: string[] = [];
  private sourcesConfigured: boolean = false;
  private emptySearchRounds: number = 0;
  private emptySearchRotationTimer: number = -1;

  constructor(
    initialQuery: string = DEFAULT_DISCOVERY_QUERY,
    keywordBatchSize: number = DEFAULT_SEARCH_KEYWORD_BATCH_SIZE
  ) {
    this.keywordBatchSize = Number.isFinite(keywordBatchSize) ? Math.max(1, Math.floor(keywordBatchSize)) : 1;
    this.currentKeyword = this.createKeywordQueue(initialQuery);
    this.pool = new WeightedFeedChannelPool({
      log: discoveryFeedLog,
      onDelivered: (channelId: string, kind: FeedChannelKind, candidate: WaterfallCandidate): void => {
        this.onPoolDelivered(channelId, kind, candidate);
      }
    });
    const queries = this.currentKeywordQueries();

    const bilibili = new BufferedSearchFeedChannel(new BilibiliSearchSourceAdapter(), queries, {
      refillThreshold: 10,
      fetchBatchSize: 10,
      availabilityHook: this.pool,
      log: discoveryFeedLog
    });
    this.registerSearch(bilibili, 2);

    const searchSources = aggregateSearchAdapterSources();
    const recommendSources = aggregateRecommendAdapterSources();
    searchSources.forEach((source: AggregateSearchSource): void => {
      if (source === 'bilibili') return;
      const adapter = new BufferedSearchFeedChannel(
        new AggregateFeedSourceAdapter(source, 'search'), queries, {
        refillThreshold: 10,
        fetchBatchSize: 10,
        availabilityHook: this.pool,
        log: discoveryFeedLog
      });
      this.registerSearch(adapter, recommendSources.indexOf(source) >= 0 ? 1 : 2);
    });

    recommendSources.forEach((source: AggregateSearchSource): void => {
      this.register(new BufferedRecommendFeedChannel(
        new AggregateFeedSourceAdapter(source, 'recommend'), {
        refillThreshold: 10,
        fetchBatchSize: 10,
        availabilityHook: this.pool,
        log: discoveryFeedLog
      }), searchSources.indexOf(source) >= 0 ? 1 : 2);
    });

    discoveryFeedLog('event=registry_ready channels=' + this.adapters.length.toString() +
      ' currentKeywords=' + JSON.stringify(queries) +
      ' keywordQueue=' + this.keywordQueueText());
  }

  setEnabledSources(sources: string[]): void {
    const available: string[] = [];
    this.adapters.forEach((adapter: FeedChannel): void => {
      if (available.indexOf(adapter.platformId) < 0) available.push(adapter.platformId);
    });
    const enabled: string[] = [];
    sources.forEach((source: string): void => {
      const normalized = source.trim();
      if (available.indexOf(normalized) >= 0 && enabled.indexOf(normalized) < 0) enabled.push(normalized);
    });
    this.enabledSources = enabled;
    this.sourcesConfigured = true;
    if (this.reserve !== null) this.reserve.setEnabledSources(enabled);
    available.forEach((platformId: string): void => {
      this.pool.setPlatformBlocked(platformId, enabled.indexOf(platformId) < 0);
    });
    discoveryFeedLog('event=sources_updated enabled=[' + enabled.join(',') + ']');
    this.maybeRotateCompletedSearchRound('sources_updated');
  }

  activate(profile?: WaterfallPreferenceSnapshot): void {
    if (this.reserve !== null) {
      this.reserve.updateProfile(profile);
      return;
    }
    const reserve = new DiscoveryFeedReserve(this.pool, {
      targetWatermark: 50,
      refillBatchSize: 5,
      profile: profile,
      log: discoveryFeedLog
    });
    this.reserve = reserve;
    if (this.sourcesConfigured) reserve.setEnabledSources(this.enabledSources);
    discoveryFeedLog('event=activated');
  }

  get(): Promise<WaterfallRankedCandidate> {
    this.activate();
    return (this.reserve as DiscoveryFeedReserve).get();
  }

  tryGet(): WaterfallRankedCandidate | null {
    this.activate();
    return (this.reserve as DiscoveryFeedReserve).tryGet();
  }

  replaceSearchQuery(query: string): void {
    this.selectKeyword(query, 'manual');
  }

  recordKeywordHeat(keyword: string, increment: number = 1): void {
    const normalized = keyword.trim();
    if (normalized.length === 0 || !Number.isFinite(increment) || increment <= 0) return;
    const amount = Math.max(1, Math.floor(increment));
    if (this.currentKeyword.keyword === normalized) {
      this.currentKeyword.heat += amount;
    } else {
      let state = this.removeQueuedKeyword(normalized);
      if (state === null) {
        state = { keyword: normalized, heat: 0, lastUsedSequence: 0 };
      }
      state.heat += amount;
      this.keywordQueue.push(state);
      this.sortKeywordQueue();
    }
    discoveryFeedLog('event=keyword_heat_updated keyword=' + JSON.stringify(normalized) +
      ' increment=' + amount.toString() + ' keywordQueue=' + this.keywordQueueText());
  }

  refreshAll(): void {
    this.adapters.forEach((adapter: FeedChannel): void => adapter.refresh());
    discoveryFeedLog('event=refresh_all channels=' + this.adapters.length.toString());
  }

  snapshot(): DiscoveryFeedChannelRegistrySnapshot {
    const pool = this.pool.snapshot();
    return {
      pointer: pool.pointer,
      pendingGets: pool.pendingGets,
      delivered: pool.delivered,
      channels: pool.channels,
      active: this.reserve !== null,
      reserve: this.reserve === null ? null : this.reserve.snapshot(),
      currentKeyword: this.currentKeyword.keyword,
      currentKeywords: this.currentKeywordQueries(),
      currentKeywordDeliveries: this.currentKeywordDeliveries,
      keywordDeliveryLimit: this.keywordDeliveryLimit(),
      keywords: this.keywordSnapshots(),
      enabledSources: this.enabledSources.slice()
    };
  }

  private createKeywordQueue(initialQuery: string): DiscoveryKeywordState {
    const values: string[] = [];
    const normalized = initialQuery.trim().length > 0 ? initialQuery.trim() : DEFAULT_DISCOVERY_QUERY;
    values.push(normalized);
    WATERFALL_EXPLORATION_QUERIES.forEach((keyword: string): void => {
      if (values.indexOf(keyword) < 0) values.push(keyword);
    });
    const states = values.map((keyword: string, index: number): DiscoveryKeywordState => {
      return { keyword, heat: 0, lastUsedSequence: index };
    });
    this.keywordUseSequence = states.length;
    const current = states.shift() as DiscoveryKeywordState;
    states.forEach((state: DiscoveryKeywordState): void => {
      this.keywordQueue.push(state);
    });
    return current;
  }

  private onPoolDelivered(channelId: string, kind: FeedChannelKind, _candidate: WaterfallCandidate): void {
    if (kind !== 'search') return;
    this.emptySearchRounds = 0;
    this.currentKeywordDeliveries++;
    discoveryFeedLog('event=keyword_delivery channel=' + channelId +
      ' keyword=' + JSON.stringify(this.currentKeyword.keyword) +
      ' count=' + this.currentKeywordDeliveries.toString() +
      ' limit=' + this.keywordDeliveryLimit().toString());
    if (this.currentKeywordDeliveries >= this.keywordDeliveryLimit()) {
      this.rotateKeyword('delivery_limit');
    } else if (this.emptySearchRotationTimer >= 0) {
      this.cancelEmptySearchRotation();
      this.maybeRotateCompletedSearchRound(channelId + '_delivery');
    }
  }

  private rotateKeyword(reason: string): void {
    this.cancelEmptySearchRotation();
    if (this.keywordQueue.length === 0) {
      this.currentKeywordDeliveries = 0;
      return;
    }
    const previous = this.currentKeyword;
    previous.heat = 0;
    previous.lastUsedSequence = ++this.keywordUseSequence;
    this.keywordQueue.push(previous);
    this.sortKeywordQueue();
    this.currentKeyword = this.keywordQueue.shift() as DiscoveryKeywordState;
    this.currentKeywordDeliveries = 0;
    this.broadcastCurrentKeyword();
    discoveryFeedLog('event=keyword_rotated reason=' + reason +
      ' previous=' + JSON.stringify(previous.keyword) +
      ' current=' + JSON.stringify(this.currentKeyword.keyword) +
      ' channels=' + this.searchAdapters.length.toString() +
      ' keywordQueue=' + this.keywordQueueText());
  }

  private selectKeyword(keyword: string, reason: string): void {
    const normalized = keyword.trim();
    if (normalized.length === 0 || normalized === this.currentKeyword.keyword) return;
    this.cancelEmptySearchRotation();
    this.emptySearchRounds = 0;
    const previous = this.currentKeyword;
    previous.lastUsedSequence = ++this.keywordUseSequence;
    this.keywordQueue.push(previous);
    const queued = this.removeQueuedKeyword(normalized);
    this.currentKeyword = queued ?? {
      keyword: normalized,
      heat: 0,
      lastUsedSequence: 0
    };
    this.currentKeywordDeliveries = 0;
    this.sortKeywordQueue();
    this.broadcastCurrentKeyword();
    discoveryFeedLog('event=keyword_selected reason=' + reason +
      ' previous=' + JSON.stringify(previous.keyword) +
      ' current=' + JSON.stringify(normalized) +
      ' channels=' + this.searchAdapters.length.toString() +
      ' keywordQueue=' + this.keywordQueueText());
  }

  private broadcastCurrentKeyword(): void {
    const queries = this.currentKeywordQueries();
    this.searchAdapters.forEach((adapter: SearchFeedChannel): void => {
      adapter.replaceQueries(queries);
    });
  }

  private currentKeywordQueries(): string[] {
    const queries: string[] = [this.currentKeyword.keyword];
    for (let index = 0; index < this.keywordQueue.length && queries.length < this.keywordBatchSize; index++) {
      const keyword = this.keywordQueue[index].keyword;
      if (queries.indexOf(keyword) < 0) queries.push(keyword);
    }
    return queries;
  }

  private keywordDeliveryLimit(): number {
    return SEARCH_DELIVERIES_PER_KEYWORD * this.currentKeywordQueries().length;
  }

  private removeQueuedKeyword(keyword: string): DiscoveryKeywordState | null {
    for (let index = 0; index < this.keywordQueue.length; index++) {
      if (this.keywordQueue[index].keyword === keyword) {
        return this.keywordQueue.splice(index, 1)[0];
      }
    }
    return null;
  }

  private sortKeywordQueue(): void {
    this.keywordQueue.sort((left: DiscoveryKeywordState, right: DiscoveryKeywordState): number => {
      if (left.heat !== right.heat) return right.heat - left.heat;
      return left.lastUsedSequence - right.lastUsedSequence;
    });
  }

  private keywordSnapshots(): DiscoveryKeywordSnapshot[] {
    const snapshots: DiscoveryKeywordSnapshot[] = [{
      keyword: this.currentKeyword.keyword,
      heat: this.currentKeyword.heat,
      lastUsedSequence: this.currentKeyword.lastUsedSequence,
      current: true
    }];
    this.keywordQueue.forEach((state: DiscoveryKeywordState): void => {
      snapshots.push({
        keyword: state.keyword,
        heat: state.heat,
        lastUsedSequence: state.lastUsedSequence,
        current: false
      });
    });
    return snapshots;
  }

  private keywordQueueText(): string {
    return this.keywordSnapshots().map((state: DiscoveryKeywordSnapshot): string => {
      return (state.current ? '*' : '') + state.keyword +
        '{heat=' + state.heat.toString() + ',last=' + state.lastUsedSequence.toString() + '}';
    }).join(',');
  }

  private registerSearch(adapter: SearchFeedChannel, weight: number): void {
    this.searchAdapters.push(adapter);
    adapter.setKeywordRoundCompletionListener((channelId: string): void => {
      this.maybeRotateCompletedSearchRound(channelId);
    });
    this.register(adapter, weight);
  }

  private maybeRotateCompletedSearchRound(completedChannelId: string): void {
    const enabledSearchAdapters = this.enabledSearchAdapters();
    if (enabledSearchAdapters.length === 0 ||
      !enabledSearchAdapters.every((adapter: SearchFeedChannel): boolean =>
        adapter.isKeywordRoundComplete())) {
      this.cancelEmptySearchRotation();
      return;
    }
    discoveryFeedLog('event=keyword_round_all_search_complete trigger=' + completedChannelId +
      ' channels=[' + enabledSearchAdapters.map((adapter: SearchFeedChannel): string => adapter.id).join(',') + ']');
    if (this.currentKeywordDeliveries > 0) {
      this.emptySearchRounds = 0;
      this.rotateKeyword('search_round_complete_with_content');
      return;
    }
    this.scheduleEmptySearchRotation();
  }

  private enabledSearchAdapters(): SearchFeedChannel[] {
    return this.searchAdapters.filter((adapter: SearchFeedChannel): boolean => {
      return !this.sourcesConfigured || this.enabledSources.indexOf(adapter.platformId) >= 0;
    });
  }

  private scheduleEmptySearchRotation(): void {
    if (this.emptySearchRotationTimer >= 0) return;
    const exponent = Math.min(this.emptySearchRounds, 5);
    const delayMs = Math.min(EMPTY_SEARCH_ROTATION_MAX_DELAY_MS,
      EMPTY_SEARCH_ROTATION_BASE_DELAY_MS * Math.pow(2, exponent));
    const keyword = this.currentKeyword.keyword;
    discoveryFeedLog('event=keyword_empty_rotation_scheduled keyword=' + JSON.stringify(keyword) +
      ' delayMs=' + delayMs.toString() + ' emptyRounds=' + this.emptySearchRounds.toString());
    this.emptySearchRotationTimer = setTimeout((): void => {
      this.emptySearchRotationTimer = -1;
      if (this.currentKeyword.keyword !== keyword) return;
      const enabled = this.enabledSearchAdapters();
      if (enabled.length === 0 || !enabled.every((adapter: SearchFeedChannel): boolean =>
        adapter.isKeywordRoundComplete())) return;
      if (this.currentKeywordDeliveries > 0) {
        this.emptySearchRounds = 0;
        this.rotateKeyword('search_round_complete_with_content');
        return;
      }
      this.emptySearchRounds++;
      this.rotateKeyword('empty_search_backoff');
    }, delayMs);
  }

  private cancelEmptySearchRotation(): void {
    if (this.emptySearchRotationTimer < 0) return;
    clearTimeout(this.emptySearchRotationTimer);
    this.emptySearchRotationTimer = -1;
  }

  private register(adapter: FeedChannel, weight: number): void {
    this.adapters.push(adapter);
    this.pool.register(adapter, weight);
  }
}

let applicationRegistry: DiscoveryFeedChannelRegistry | null = null;

export function discoveryFeedChannelRegistry(): DiscoveryFeedChannelRegistry {
  if (applicationRegistry === null) {
    applicationRegistry = new DiscoveryFeedChannelRegistry();
  }
  return applicationRegistry;
}
