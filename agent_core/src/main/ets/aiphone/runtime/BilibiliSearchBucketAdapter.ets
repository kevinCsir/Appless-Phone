import { BufferedFeedChannelOptions, BufferedSearchFeedChannel } from './BufferedFeedChannel';
import { BilibiliSearchPageLoader, BilibiliSearchSourceAdapter } from './BilibiliSearchSourceAdapter';

export interface BilibiliSearchBucketOptions extends BufferedFeedChannelOptions {
  /** @deprecated Use refillThreshold. */
  lowWatermark?: number;
  /** @deprecated The channel target equals refillThreshold. */
  targetWatermark?: number;
  /** @deprecated Use fetchBatchSize. */
  pageSize?: number;
  loadPage?: BilibiliSearchPageLoader;
}

/** Compatibility facade; production code composes the source and buffered channel explicitly. */
export class BilibiliSearchBucketAdapter extends BufferedSearchFeedChannel {
  constructor(query: string | string[], options: BilibiliSearchBucketOptions = {}) {
    super(new BilibiliSearchSourceAdapter(options.loadPage), query, {
      refillThreshold: options.refillThreshold ?? options.lowWatermark,
      fetchBatchSize: options.fetchBatchSize ?? options.pageSize,
      availabilityHook: options.availabilityHook,
      log: options.log,
      maxConcurrentRequests: options.maxConcurrentRequests
    });
  }
}
