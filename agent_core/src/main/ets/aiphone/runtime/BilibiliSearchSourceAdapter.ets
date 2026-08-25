import { aggregateMediaCandidates, aggregateVideoSourceBatchFromDynamicResults } from './AggregateSearchClient';
import { callBilibiliVideoSearch } from './BilibiliApiClient';
import { FeedSourceAdapter, FeedSourcePage, FeedSourceRequest } from './FeedSourceAdapter';
import { DynamicGenericToolResult } from './DynamicToolTypes';
import { WaterfallContinuation } from './WaterfallAnythingCore';

export type BilibiliSearchPageLoader = (
  query: string,
  page: number
) => Promise<DynamicGenericToolResult[]>;

/** Bilibili-specific page loading and result normalization, with no local bucket state. */
export class BilibiliSearchSourceAdapter implements FeedSourceAdapter {
  readonly id: string = 'bilibili:search';
  readonly platformId: string = 'bilibili';
  readonly kind: 'search' = 'search';
  private readonly loadPage: BilibiliSearchPageLoader;

  constructor(loadPage: BilibiliSearchPageLoader = callBilibiliVideoSearch) {
    this.loadPage = loadPage;
  }

  async load(request: FeedSourceRequest): Promise<FeedSourcePage> {
    const page = this.pageFrom(request.continuation);
    const previous: WaterfallContinuation | null = page > 1 ?
      { kind: 'page', value: page.toString() } : null;
    const dynamic = await this.loadPage(request.query, page);
    const batch = aggregateVideoSourceBatchFromDynamicResults(
      'bilibili', dynamic, previous, request.limit);
    let phase: 'ready' | 'empty' | 'error' | 'exhausted' = 'ready';
    if (batch.status.status === 'error' || batch.status.status === 'needs_auth') phase = 'error';
    else if (batch.continuation === null) phase = dynamic.length === 0 ? 'empty' : 'exhausted';
    else if (dynamic.length === 0) phase = 'empty';
    return {
      candidates: aggregateMediaCandidates(batch.videos, batch.posts, 0, request.query,
        'original', 'search', 1),
      continuation: batch.continuation,
      phase,
      message: batch.status.message
    };
  }

  private pageFrom(continuation: WaterfallContinuation | null): number {
    if (continuation === null || continuation.kind !== 'page') return 1;
    const value = Number(continuation.value);
    return Number.isFinite(value) ? Math.max(1, Math.floor(value)) : 1;
  }
}
