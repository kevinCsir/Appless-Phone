import { describe, expect, it } from '@ohos/hypium';
import {
  AggregateFeedChannelLoadRequest,
  AggregateFeedChannelPage,
  AggregateFeedChannelPageLoader,
  AggregateRecommendBucketAdapter,
  AggregateSearchBucketAdapter,
  DiscoveryFeedReserve,
  FeedChannelAdapter,
  FeedChannelAvailabilityHook,
  FeedChannelAvailabilityListener,
  FeedChannelSnapshot,
  WaterfallCandidate,
  WaterfallContinuation,
  WeightedFeedChannelPool,
  WeightedFeedChannelPoolSnapshot
} from '@loop/agent-core';

function candidate(source: string, id: string): WaterfallCandidate {
  return {
    id: source + '-' + id,
    source,
    mediaType: source === 'youtube' || source === 'bilibili' ? 'video' : 'post',
    title: source + ' ' + id,
    summary: 'weighted pool test candidate',
    url: 'https://feed.test/' + source + '/' + id,
    coverUrl: '',
    publishedAt: '',
    originalIndex: 0
  };
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout(resolve, ms);
  });
}

function fakePageLoader(source: string): AggregateFeedChannelPageLoader {
  return (request: AggregateFeedChannelLoadRequest): Promise<AggregateFeedChannelPage> => {
    let page = 1;
    if (request.continuation !== null && request.continuation.kind === 'page') {
      const parsed = Number(request.continuation.value);
      page = Number.isFinite(parsed) ? Math.max(1, Math.floor(parsed)) : 1;
    }
    const candidates: WaterfallCandidate[] = [];
    for (let index = 0; index < request.limit; index++) {
      candidates.push(candidate(source, page.toString() + '-' + index.toString()));
    }
    const continuation: WaterfallContinuation = {
      kind: 'page',
      value: (page + 1).toString()
    };
    const result: AggregateFeedChannelPage = {
      candidates,
      continuation,
      phase: 'ready',
      message: 'fake page ready'
    };
    return Promise.resolve(result);
  };
}

class TestFeedAdapter implements FeedChannelAdapter {
  readonly id: string;
  readonly platformId: string;
  readonly kind: 'recommend' = 'recommend';
  private readonly items: WaterfallCandidate[] = [];
  private readonly hook: FeedChannelAvailabilityHook;
  private listener: FeedChannelAvailabilityListener | null = null;

  constructor(id: string, hook: FeedChannelAvailabilityHook) {
    this.id = id;
    this.platformId = id;
    this.hook = hook;
  }

  push(item: WaterfallCandidate): void {
    const wasEmpty = this.items.length === 0;
    this.items.push(item);
    if (wasEmpty) {
      this.hook.onFeedChannelAvailable(this.id);
      if (this.listener !== null) this.listener();
    }
  }

  tryTake(): WaterfallCandidate | null {
    return this.items.length === 0 ? null : this.items.shift() as WaterfallCandidate;
  }

  ensureWatermark(): void {}

  refresh(): void {}

  setAvailabilityListener(listener: FeedChannelAvailabilityListener | null): void {
    this.listener = listener;
  }

  snapshot(): FeedChannelSnapshot {
    return {
      id: this.id,
      platformId: this.platformId,
      kind: this.kind,
      phase: this.items.length > 0 ? 'ready' : 'empty',
      size: this.items.length,
      lowWatermark: 1,
      targetWatermark: 1,
      continuation: null,
      query: '',
      generation: 0,
      message: ''
    };
  }

  close(): void {
    this.items.splice(0, this.items.length);
  }
}

function debtFor(snapshot: WeightedFeedChannelPoolSnapshot, id: string): number {
  for (let index = 0; index < snapshot.channels.length; index++) {
    if (snapshot.channels[index].id === id) return snapshot.channels[index].debt;
  }
  return -1;
}

export default function weightedFeedChannelPoolTest() {
  describe('weightedFeedChannelPool', () => {
    it('skips an empty weighted channel, records one debt, and repays weight plus debt', 0, () => {
      const pool = new WeightedFeedChannelPool();
      const first = new TestFeedAdapter('first:recommend', pool);
      const second = new TestFeedAdapter('second:recommend', pool);
      second.push(candidate('second', '1'));
      pool.register(first, 2);
      pool.register(second, 1);

      expect((pool.tryGet() as WaterfallCandidate).source).assertEqual('second');
      expect(debtFor(pool.snapshot(), 'first:recommend')).assertEqual(1);

      first.push(candidate('first', '1'));
      first.push(candidate('first', '2'));
      first.push(candidate('first', '3'));
      expect((pool.tryGet() as WaterfallCandidate).source).assertEqual('first');
      expect((pool.tryGet() as WaterfallCandidate).source).assertEqual('first');
      expect((pool.tryGet() as WaterfallCandidate).source).assertEqual('first');
      expect(debtFor(pool.snapshot(), 'first:recommend')).assertEqual(0);
      pool.close();
    });

    it('wakes a blocked get through the adapter construction hook', 0, async () => {
      const pool = new WeightedFeedChannelPool();
      const adapter = new TestFeedAdapter('wake:recommend', pool);
      pool.register(adapter, 1);

      const pending = pool.get();
      expect(pool.snapshot().pendingGets).assertEqual(1);
      adapter.push(candidate('wake', '1'));
      const result = await pending;

      expect(result.source).assertEqual('wake');
      expect(pool.snapshot().pendingGets).assertEqual(0);
      pool.close();
    });

    it('makes the first reserve refill visible without waiting for a five-item batch', 0, async () => {
      const pool = new WeightedFeedChannelPool();
      const adapter = new TestFeedAdapter('streaming:recommend', pool);
      adapter.push(candidate('streaming', '1'));
      pool.register(adapter, 1);
      const reserve = new DiscoveryFeedReserve(pool, {
        targetWatermark: 1,
        refillBatchSize: 5
      });

      await Promise.resolve();
      await Promise.resolve();
      const first = reserve.tryGet();

      expect(first === null ? '' : first.source).assertEqual('streaming');
      reserve.close();
      pool.close();
    });

    it('prewarms for five seconds then logs thirty weighted gets and debts', 0, async () => {
      const pool = new WeightedFeedChannelPool({
        log: (message: string): void => console.info('[FeedPool30] ' + message)
      });
      const bilibili = new AggregateSearchBucketAdapter('bilibili', '科技', {
        availabilityHook: pool,
        loadPage: fakePageLoader('bilibili'),
        log: (message: string): void => console.info('[FeedPool30] ' + message)
      });
      const youtube = new AggregateSearchBucketAdapter('youtube', 'technology', {
        availabilityHook: pool,
        loadPage: fakePageLoader('youtube'),
        log: (message: string): void => console.info('[FeedPool30] ' + message)
      });
      const twitch = new AggregateRecommendBucketAdapter('twitch', {
        availabilityHook: pool,
        loadPage: fakePageLoader('twitch'),
        log: (message: string): void => console.info('[FeedPool30] ' + message)
      });
      pool.register(bilibili, 2);
      pool.register(youtube, 1);
      pool.register(twitch, 1);

      await delay(5000);

      let bilibiliCount = 0;
      let youtubeCount = 0;
      let twitchCount = 0;
      for (let index = 0; index < 30; index++) {
        const item = await pool.get();
        if (item.source === 'bilibili') bilibiliCount++;
        if (item.source === 'youtube') youtubeCount++;
        if (item.source === 'twitch') twitchCount++;
        const current = pool.snapshot();
        console.info('[FeedPool30] take=' + (index + 1).toString() +
          ' source=' + item.source +
          ' debts=' + current.channels.map((channel): string =>
            channel.id + ':' + channel.debt.toString()).join(','));
      }

      const finalSnapshot = pool.snapshot();
      console.info('[FeedPool30] final sources=bilibili:' + bilibiliCount.toString() +
        ',youtube:' + youtubeCount.toString() +
        ',twitch:' + twitchCount.toString() +
        ' snapshot=' + JSON.stringify(finalSnapshot));
      expect(bilibiliCount).assertEqual(16);
      expect(youtubeCount).assertEqual(7);
      expect(twitchCount).assertEqual(7);
      expect(debtFor(finalSnapshot, 'bilibili:search')).assertEqual(0);
      expect(debtFor(finalSnapshot, 'youtube:search')).assertEqual(0);
      expect(debtFor(finalSnapshot, 'twitch:recommend')).assertEqual(0);
      pool.close();
    });
    it('starts a second Hacker News page at double-watermark debt and exposes whichever returns first', 0, async () => {
      let resolvePage0: (page: AggregateFeedChannelPage) => void = (_page: AggregateFeedChannelPage): void => {};
      let resolvePage1: (page: AggregateFeedChannelPage) => void = (_page: AggregateFeedChannelPage): void => {};
      const requested: number[] = [];
      const logs: string[] = [];
      const loader: AggregateFeedChannelPageLoader =
        (request: AggregateFeedChannelLoadRequest): Promise<AggregateFeedChannelPage> => {
          const page = request.continuation === null ? 0 : Number(request.continuation.value);
          requested.push(page);
          return new Promise<AggregateFeedChannelPage>((resolve: (value: AggregateFeedChannelPage) => void): void => {
            if (page === 0) resolvePage0 = resolve;
            else resolvePage1 = resolve;
          });
        };
      const adapter = new AggregateSearchBucketAdapter('hackernews', 'AI', {
        refillThreshold: 2, fetchBatchSize: 2, maxConcurrentRequests: 2, loadPage: loader,
        log: (message: string): void => { logs.push(message); }
      });
      adapter.ensureWatermark(4);
      expect(requested.join(',')).assertEqual('0,1');

      resolvePage1({
        candidates: [candidate('hackernews', 'page-1-a'), candidate('hackernews', 'page-1-b')],
        continuation: { kind: 'page', value: '2' }, phase: 'ready', message: 'page 1'
      });
      await Promise.resolve();
      await Promise.resolve();
      expect(adapter.snapshot().size).assertEqual(2);
      expect((adapter.tryTake() as WaterfallCandidate).id).assertEqual('hackernews-page-1-a');

      resolvePage0({
        candidates: [candidate('hackernews', 'page-0-a'), candidate('hackernews', 'page-0-b')],
        continuation: { kind: 'page', value: '1' }, phase: 'ready', message: 'page 0'
      });
      await Promise.resolve();
      await Promise.resolve();
      expect(adapter.snapshot().size).assertEqual(3);
      expect(logs.some((message: string): boolean => message.indexOf('request_finished') >= 0 &&
        message.indexOf('elapsedMs=') >= 0)).assertTrue();
      adapter.close();
    });

  });
}
