import { describe, expect, it } from '@ohos/hypium';
import {
  BilibiliSearchBucketAdapter,
  BilibiliSearchPageLoader,
  DynamicGenericToolResult,
  WaterfallCandidate
} from '@loop/agent-core';

type DynamicResultsResolver = (results: DynamicGenericToolResult[]) => void;

function bilibiliResult(id: string, title: string): DynamicGenericToolResult {
  return {
    sourceTag: '哔哩哔哩', toolName: 'media.video.search', title, status: 'success',
    summary: title + ' summary',
    rows: [
      { label: 'Query', value: title }, { label: 'BVID', value: id },
      { label: 'Playback URL', value: 'https://www.bilibili.com/video/' + id },
      { label: 'Thumbnail', value: 'https://image.test/' + id + '.jpg' }
    ],
    rawPreview: '{}'
  };
}

async function flushPromises(rounds: number = 4): Promise<void> {
  for (let index = 0; index < rounds; index++) await Promise.resolve();
}

export default function bilibiliSearchBucketAdapterTest() {
  describe('bilibiliSearchBucketAdapter', () => {
    it('keeps tryTake non-blocking and notifies only on empty-to-non-empty', 0, async () => {
      let notifications = 0;
      const loader: BilibiliSearchPageLoader = (_query: string, _page: number) => Promise.resolve([
        bilibiliResult('BV1', 'first'), bilibiliResult('BV2', 'second')
      ]);
      const adapter = new BilibiliSearchBucketAdapter('人工智能', {
        lowWatermark: 1, targetWatermark: 2, pageSize: 2, loadPage: loader
      });
      adapter.setAvailabilityListener((): void => { notifications++; });

      expect(adapter.tryTake()).assertNull();
      await flushPromises();

      expect(adapter.snapshot().size).assertEqual(2);
      expect(notifications).assertEqual(1);
      expect((adapter.tryTake() as WaterfallCandidate).id).assertEqual('bilibili-BV1');
      expect(adapter.snapshot().size).assertEqual(1);
      adapter.close();
    });

    it('refills from the next page after crossing the low watermark', 0, async () => {
      const pages: number[] = [];
      const loader: BilibiliSearchPageLoader = (_query: string, page: number) => {
        pages.push(page);
        return Promise.resolve([
          bilibiliResult('BV' + page.toString() + 'A', 'page ' + page.toString() + ' a'),
          bilibiliResult('BV' + page.toString() + 'B', 'page ' + page.toString() + ' b')
        ]);
      };
      const adapter = new BilibiliSearchBucketAdapter('科技数码', {
        refillThreshold: 2, fetchBatchSize: 2, loadPage: loader
      });
      await flushPromises();
      adapter.tryTake();
      await flushPromises();

      expect(pages.join(',')).assertEqual('1,2');
      expect(adapter.snapshot().size).assertEqual(3);
      expect(adapter.snapshot().continuation?.value).assertEqual('3');
      adapter.close();
    });

    it('warms ten items and refills one full batch from 9 to 19', 0, async () => {
      const pages: number[] = [];
      const loader: BilibiliSearchPageLoader = (_query: string, page: number) => {
        pages.push(page);
        const results: DynamicGenericToolResult[] = [];
        for (let index = 0; index < 10; index++) {
          results.push(bilibiliResult(
            'BV' + page.toString() + '-' + index.toString(),
            'page ' + page.toString() + ' item ' + index.toString()
          ));
        }
        return Promise.resolve(results);
      };
      const adapter = new BilibiliSearchBucketAdapter('启动预热', { loadPage: loader });

      await flushPromises(8);
      expect(pages.join(',')).assertEqual('1');
      expect(adapter.snapshot().lowWatermark).assertEqual(10);
      expect(adapter.snapshot().targetWatermark).assertEqual(10);
      expect(adapter.snapshot().size).assertEqual(10);

      adapter.tryTake();
      await flushPromises(8);
      expect(pages.join(',')).assertEqual('1,2');
      expect(adapter.snapshot().size).assertEqual(19);
      adapter.close();
    });

    it('drops duplicate platform items before exposing them', 0, async () => {
      const loader: BilibiliSearchPageLoader = (_query: string, _page: number) => Promise.resolve([
        bilibiliResult('BV-DUP', 'duplicate'), bilibiliResult('BV-DUP', 'duplicate again')
      ]);
      const adapter = new BilibiliSearchBucketAdapter('编程开发', {
        lowWatermark: 1, targetWatermark: 2, pageSize: 2, loadPage: loader
      });

      adapter.ensureWatermark();
      await flushPromises(8);

      expect(adapter.snapshot().size).assertEqual(1);
      expect((adapter.tryTake() as WaterfallCandidate).id).assertEqual('bilibili-BV-DUP');
      adapter.close();
    });

    it('ignores a late batch from the query replaced during refill', 0, async () => {
      let resolveOld: DynamicResultsResolver = (_results: DynamicGenericToolResult[]): void => {};
      const queries: string[] = [];
      const loader: BilibiliSearchPageLoader = (query: string, _page: number) => {
        queries.push(query);
        if (query === '旧词') {
          return new Promise<DynamicGenericToolResult[]>((resolve: DynamicResultsResolver): void => {
            resolveOld = resolve;
          });
        }
        return Promise.resolve([bilibiliResult('BV-NEW', 'new query')]);
      };
      const adapter = new BilibiliSearchBucketAdapter('旧词', {
        lowWatermark: 1, targetWatermark: 2, pageSize: 2, loadPage: loader
      });

      adapter.ensureWatermark();
      await flushPromises();
      adapter.replaceQuery('新词');
      await flushPromises();
      resolveOld([bilibiliResult('BV-OLD', 'old query')]);
      await flushPromises();

      expect(queries.join(',')).assertEqual('旧词,新词');
      expect(adapter.snapshot().query).assertEqual('新词');
      expect(adapter.snapshot().size).assertEqual(1);
      expect((adapter.tryTake() as WaterfallCandidate).id).assertEqual('bilibili-BV-NEW');
      adapter.close();
    });
  });
}
