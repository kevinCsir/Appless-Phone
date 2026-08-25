import {
  AggregateRecommendBucketAdapter,
  AggregateSearchBucketAdapter,
  AggregateSearchSource,
  BilibiliSearchBucketAdapter,
  DiscoveryFeedReserve,
  DiscoveryFeedReserveSnapshot,
  FeedChannelAdapter,
  FeedChannelKind,
  SearchFeedChannelAdapter,
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
  currentKeywordDeliveries: number;
  keywordDeliveryLimit: number;
  keywords: DiscoveryKeywordSnapshot[];
  enabledSources: string[];
}

/**
 * Application-wide registry for discovery feed channels.
 *
 * Constructing the registry constructs every adapter, which immediately starts
 * its first 10-item prefetch. The weighted pool is the single blocking source
 * that the reserve layer can consume.
 */
export class DiscoveryFeedChannelRegistry {
  private readonly pool: WeightedFeedChannelPool;
  private reserve: DiscoveryFeedReserve | null = null;
  private readonly searchAdapters: SearchFeedChannelAdapter[] = [];
  private readonly adapters: FeedChannelAdapter[] = [];
  private readonly keywordQueue: DiscoveryKeywordState[] = [];
  private currentKeyword: DiscoveryKeywordState;
  private keywordUseSequence: number = 0;
  private currentKeywordDeliveries: number = 0;
  private enabledSources: string[] = [];
  private sourcesConfigured: boolean = false;

  constructor(initialQuery: string = DEFAULT_DISCOVERY_QUERY) {
    this.currentKeyword = this.createKeywordQueue(initialQuery);
    this.pool = new WeightedFeedChannelPool({
      log: discoveryFeedLog,
      onDelivered: (channelId: string, kind: FeedChannelKind, candidate: WaterfallCandidate): void => {
        this.onPoolDelivered(channelId, kind, candidate);
      }
    });
    const query = this.currentKeyword.keyword;

    const bilibili = new BilibiliSearchBucketAdapter(query, {
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
      const adapter = new AggregateSearchBucketAdapter(source, query, {
        refillThreshold: 10,
        fetchBatchSize: 10,
        availabilityHook: this.pool,
        maxConcurrentRequests: source === 'hackernews' ? 2 : 1,
        log: discoveryFeedLog
      });
      this.registerSearch(adapter, recommendSources.indexOf(source) >= 0 ? 1 : 2);
    });

    recommendSources.forEach((source: AggregateSearchSource): void => {
      this.register(new AggregateRecommendBucketAdapter(source, {
        refillThreshold: 10,
        fetchBatchSize: 10,
        availabilityHook: this.pool,
        log: discoveryFeedLog
      }), searchSources.indexOf(source) >= 0 ? 1 : 2);
    });

    discoveryFeedLog('event=registry_ready channels=' + this.adapters.length.toString() +
      ' currentKeyword=' + JSON.stringify(query) +
      ' keywordQueue=' + this.keywordQueueText());
  }

  setEnabledSources(sources: string[]): void {
    const available: string[] = [];
    this.adapters.forEach((adapter: FeedChannelAdapter): void => {
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
    this.adapters.forEach((adapter: FeedChannelAdapter): void => adapter.refresh());
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
      currentKeywordDeliveries: this.currentKeywordDeliveries,
      keywordDeliveryLimit: SEARCH_DELIVERIES_PER_KEYWORD,
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
    this.currentKeywordDeliveries++;
    discoveryFeedLog('event=keyword_delivery channel=' + channelId +
      ' keyword=' + JSON.stringify(this.currentKeyword.keyword) +
      ' count=' + this.currentKeywordDeliveries.toString() +
      ' limit=' + SEARCH_DELIVERIES_PER_KEYWORD.toString());
    if (this.currentKeywordDeliveries >= SEARCH_DELIVERIES_PER_KEYWORD) {
      this.rotateKeyword();
    }
  }

  private rotateKeyword(): void {
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
    discoveryFeedLog('event=keyword_rotated previous=' + JSON.stringify(previous.keyword) +
      ' current=' + JSON.stringify(this.currentKeyword.keyword) +
      ' channels=' + this.searchAdapters.length.toString() +
      ' keywordQueue=' + this.keywordQueueText());
  }

  private selectKeyword(keyword: string, reason: string): void {
    const normalized = keyword.trim();
    if (normalized.length === 0 || normalized === this.currentKeyword.keyword) return;
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
    const query = this.currentKeyword.keyword;
    this.searchAdapters.forEach((adapter: SearchFeedChannelAdapter): void => {
      adapter.replaceQuery(query);
    });
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

  private registerSearch(adapter: SearchFeedChannelAdapter, weight: number): void {
    this.searchAdapters.push(adapter);
    this.register(adapter, weight);
  }

  private register(adapter: FeedChannelAdapter, weight: number): void {
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
