import { aggregateMediaCandidates } from './AggregateSearchClient';
import { aggregateSearchSearchSourceIds } from './AggregateSearchSourceRegistry';
import { AggregateSearchSource, AggregateSearchSourceBatch } from './AggregateSearchTypes';
import {
  BufferedFeedChannelOptions,
  BufferedRecommendFeedChannel,
  BufferedSearchFeedChannel
} from './BufferedFeedChannel';
import { FeedChannelKind, FeedChannelPhase } from './FeedChannelAdapter';
import { FeedSourceAdapter, FeedSourcePage, FeedSourceRequest } from './FeedSourceAdapter';
import {
  callConfiguredAggregateSearchContinuation,
  callConfiguredWaterfallInterestRecall,
  WaterfallInterestRecallBatch
} from './ToolGatewayClient';
import {
  WaterfallContinuation,
  WaterfallInterestRecallRequest,
  WaterfallLoadRequest
} from './WaterfallAnythingCore';

export interface AggregateFeedChannelLoadRequest extends FeedSourceRequest {
  source: AggregateSearchSource;
  kind: FeedChannelKind;
}

export interface AggregateFeedChannelPage extends FeedSourcePage {}

export type AggregateFeedChannelPageLoader = (
  request: AggregateFeedChannelLoadRequest
) => Promise<AggregateFeedChannelPage>;

export interface AggregateFeedBucketOptions extends BufferedFeedChannelOptions {
  loadPage?: AggregateFeedChannelPageLoader;
}

class AggregateBatchHolder { value: AggregateSearchSourceBatch | null = null; }
class InterestBatchHolder { value: WaterfallInterestRecallBatch | null = null; }

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
    source: request.source, continuation: request.continuation, limit: request.limit,
    phase: 'loading', message: '', mode: 'search', query: request.query, route: 'explore'
  };
  await callConfiguredAggregateSearchContinuation(request.query, [load],
    (batch: AggregateSearchSourceBatch): void => { holder.value = batch; });
  const batch = holder.value;
  if (batch === null) {
    return { candidates: [], continuation: null, phase: 'error',
      message: 'No aggregate search batch returned for ' + request.source + '.' };
  }
  return {
    candidates: aggregateMediaCandidates(batch.videos, batch.posts, 0, request.query,
      'original', 'search', 1),
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
    route: request.source === 'twitch' ? 'explore' : 'popular', query: '',
    sources: [request.source], weight: 1, continuation: request.continuation
  };
  await callConfiguredWaterfallInterestRecall([recall],
    (result: WaterfallInterestRecallBatch): void => { holder.value = result; });
  const result = holder.value;
  if (result === null) {
    return { candidates: [], continuation: null, phase: 'error',
      message: 'No recommendation batch returned for ' + request.source + '.' };
  }
  const phase = phaseFromBatch(result.batch);
  return {
    candidates: result.candidates,
    continuation: result.batch.continuation,
    phase: result.batch.continuation === null && phase !== 'error' ? 'exhausted' : phase,
    message: result.batch.status.message
  };
}

/** Platform-specific loader only; buffering and scheduling are composed separately. */
export class AggregateFeedSourceAdapter implements FeedSourceAdapter {
  readonly id: string;
  readonly platformId: string;
  readonly kind: FeedChannelKind;
  private readonly source: AggregateSearchSource;
  private readonly loadPage: AggregateFeedChannelPageLoader;

  constructor(source: AggregateSearchSource, kind: FeedChannelKind,
    loadPage?: AggregateFeedChannelPageLoader) {
    if (kind === 'search' && aggregateSearchAdapterSources().indexOf(source) < 0) {
      throw new Error(source + ' does not support aggregate search.');
    }
    if (kind === 'recommend' && aggregateRecommendAdapterSources().indexOf(source) < 0) {
      throw new Error(source + ' does not expose a keyword-free recommendation channel.');
    }
    this.source = source;
    this.platformId = source;
    this.kind = kind;
    this.id = source + ':' + kind;
    this.loadPage = loadPage ?? (kind === 'search' ?
      loadAggregateSearchFeedPage : loadAggregateRecommendFeedPage);
  }

  load(request: FeedSourceRequest): Promise<FeedSourcePage> {
    return this.loadPage({ source: this.source, kind: this.kind,
      query: request.query, continuation: request.continuation, limit: request.limit });
  }
}

/** Compatibility facade. New code should compose AggregateFeedSourceAdapter + BufferedSearchFeedChannel. */
export class AggregateSearchBucketAdapter extends BufferedSearchFeedChannel {
  constructor(source: AggregateSearchSource, query: string | string[],
    options: AggregateFeedBucketOptions = {}) {
    if (aggregateSearchSearchSourceIds().indexOf(source) < 0) {
      throw new Error(source + ' does not support aggregate search.');
    }
    super(new AggregateFeedSourceAdapter(source, 'search', options.loadPage), query, {
      refillThreshold: options.refillThreshold, fetchBatchSize: options.fetchBatchSize,
      availabilityHook: options.availabilityHook, log: options.log,
      maxConcurrentRequests: options.maxConcurrentRequests,
      parallelPageMode: source === 'hackernews'
    });
  }
}

/** Compatibility facade. New code should compose AggregateFeedSourceAdapter + BufferedRecommendFeedChannel. */
export class AggregateRecommendBucketAdapter extends BufferedRecommendFeedChannel {
  constructor(source: AggregateSearchSource, options: AggregateFeedBucketOptions = {}) {
    if (aggregateRecommendAdapterSources().indexOf(source) < 0) {
      throw new Error(source + ' does not expose a keyword-free recommendation channel.');
    }
    super(new AggregateFeedSourceAdapter(source, 'recommend', options.loadPage), options);
  }
}

export function aggregateSearchAdapterSources(): AggregateSearchSource[] {
  return aggregateSearchSearchSourceIds();
}

export function aggregateRecommendAdapterSources(): AggregateSearchSource[] {
  return ['youtube', 'zhihu', 'twitch', 'github', 'steam', 'cnnews', 'globalnews'];
}
