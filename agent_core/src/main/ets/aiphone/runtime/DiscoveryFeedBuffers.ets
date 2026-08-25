import {
  WaterfallCandidate,
  WaterfallPreferenceSnapshot,
  WaterfallRankedCandidate,
  rankWaterfallCandidates
} from './WaterfallAnythingCore';
import { WeightedFeedChannelPool } from './WeightedFeedChannelPool';

export interface DiscoveryFeedReserveOptions {
  targetWatermark?: number;
  refillBatchSize?: number;
  profile?: WaterfallPreferenceSnapshot;
  now?: () => number;
  log?: (message: string) => void;
}

export interface DiscoveryFeedTailOptions {
  lowWatermark?: number;
  refillBatchSize?: number;
  log?: (message: string) => void;
}

export interface DiscoveryFeedReserveSnapshot {
  size: number;
  targetWatermark: number;
  refillBatchSize: number;
  pendingGets: number;
  refillRunning: boolean;
  rankedBatches: number;
  upstreamGets: number;
}

export interface DiscoveryFeedTailSnapshot {
  size: number;
  lowWatermark: number;
  refillBatchSize: number;
  pendingGets: number;
  refillRunning: boolean;
  refillBatches: number;
  upstreamGets: number;
}

type RankedCandidateResolve = (candidate: WaterfallRankedCandidate) => void;

function positiveInteger(value: number | undefined, fallback: number): number {
  if (value === undefined || !Number.isFinite(value)) return fallback;
  return Math.max(1, Math.floor(value));
}

function candidateSources(candidates: WaterfallCandidate[]): string[] {
  const sources: string[] = [];
  candidates.forEach((candidate: WaterfallCandidate): void => {
    if (candidate.source.length > 0 && sources.indexOf(candidate.source) < 0) sources.push(candidate.source);
  });
  return sources;
}

/** Ranked reserve with one serialized producer. Each upstream item becomes visible immediately. */
export class DiscoveryFeedReserve {
  private readonly upstream: WeightedFeedChannelPool;
  private readonly targetWatermark: number;
  private readonly refillBatchSize: number;
  private readonly now: () => number;
  private readonly log: ((message: string) => void) | null;
  private readonly pendingGets: RankedCandidateResolve[] = [];
  private ranked: WaterfallRankedCandidate[] = [];
  private headIndex: number = 0;
  private profile: WaterfallPreferenceSnapshot | undefined;
  private refillRunning: boolean = false;
  private closed: boolean = false;
  private rankedBatches: number = 0;
  private upstreamGets: number = 0;

  constructor(upstream: WeightedFeedChannelPool, options: DiscoveryFeedReserveOptions = {}) {
    this.upstream = upstream;
    this.targetWatermark = positiveInteger(options.targetWatermark, 50);
    this.refillBatchSize = positiveInteger(options.refillBatchSize, 5);
    this.profile = options.profile;
    this.now = options.now ?? (() => Date.now());
    this.log = options.log ?? null;
    this.logState('constructed');
    this.ensureWatermark();
  }

  tryGet(): WaterfallRankedCandidate | null {
    this.logState('try_get_requested');
    if (this.closed) return null;
    const candidate = this.takeImmediate();
    this.logState(candidate === null ? 'try_get_empty' : 'get_returned',
      candidate === null ? '' : 'candidate=' + candidate.id + ' source=' + candidate.source);
    this.ensureWatermark();
    return candidate;
  }

  get(): Promise<WaterfallRankedCandidate> {
    this.logState('get_requested');
    const immediate = this.tryGet();
    if (immediate !== null) return Promise.resolve(immediate);
    return new Promise<WaterfallRankedCandidate>((resolve: RankedCandidateResolve): void => {
      this.pendingGets.push(resolve);
      this.logState('get_blocked');
      this.ensureWatermark();
    });
  }

  ensureWatermark(): void {
    if (this.closed || this.refillRunning || this.size() >= this.targetWatermark) return;
    this.refillRunning = true;
    this.logState('refill_started');
    void this.runRefillLoop();
  }

  updateProfile(profile: WaterfallPreferenceSnapshot | undefined): void {
    this.profile = profile;
    if (this.size() === 0) return;
    this.ranked = this.rank(this.remainingCandidates());
    this.headIndex = 0;
    this.rankedBatches++;
    this.logState('profile_reranked');
    this.drainPendingGets();
  }

  snapshot(): DiscoveryFeedReserveSnapshot {
    return {
      size: this.size(),
      targetWatermark: this.targetWatermark,
      refillBatchSize: this.refillBatchSize,
      pendingGets: this.pendingGets.length,
      refillRunning: this.refillRunning,
      rankedBatches: this.rankedBatches,
      upstreamGets: this.upstreamGets
    };
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.ranked.splice(0, this.ranked.length);
    this.pendingGets.splice(0, this.pendingGets.length);
    this.headIndex = 0;
    this.logState('closed');
  }

  private async runRefillLoop(): Promise<void> {
    let failed = false;
    try {
      while (!this.closed && this.size() < this.targetWatermark) {
        this.logState('upstream_get_started', 'slot=1');
        const candidate = await this.upstream.get();
        this.logState('upstream_get_returned', 'slot=1 candidate=' + candidate.id +
          ' source=' + candidate.source);
        this.upstreamGets++;
        if (!this.closed) this.insertRankedBatch([candidate]);
      }
    } catch (error) {
      failed = true;
      const message = error instanceof Error ? error.message : 'Unknown reserve refill failure.';
      this.logState('refill_failed', message.substring(0, 200));
    } finally {
      this.refillRunning = false;
      this.logState('refill_stopped');
      if (!failed && !this.closed && this.size() < this.targetWatermark) this.ensureWatermark();
    }
  }

  private insertRankedBatch(batch: WaterfallCandidate[]): void {
    const candidates = this.remainingCandidates().concat(batch);
    const startedAt = Date.now();
    this.logState('batch_rank_started', 'received=' + batch.length.toString() +
      ' total=' + candidates.length.toString());
    this.ranked = this.rank(candidates);
    this.headIndex = 0;
    this.rankedBatches++;
    this.logState('batch_ranked', 'received=' + batch.length.toString() +
      ' elapsedMs=' + (Date.now() - startedAt).toString());
    this.drainPendingGets();
  }

  private rank(candidates: WaterfallCandidate[]): WaterfallRankedCandidate[] {
    return rankWaterfallCandidates({
      query: '',
      candidates,
      enabledSources: candidateSources(candidates),
      shownIds: [],
      stableIds: [],
      preferenceDescription: '',
      mode: 'interest',
      profile: this.profile
    }, this.now());
  }

  private remainingCandidates(): WaterfallCandidate[] {
    const candidates: WaterfallCandidate[] = [];
    for (let index = this.headIndex; index < this.ranked.length; index++) candidates.push(this.ranked[index]);
    return candidates;
  }

  private takeImmediate(): WaterfallRankedCandidate | null {
    if (this.headIndex >= this.ranked.length) return null;
    const candidate = this.ranked[this.headIndex++];
    if (this.headIndex >= this.ranked.length) {
      this.ranked = [];
      this.headIndex = 0;
    }
    return candidate;
  }

  private size(): number {
    return Math.max(0, this.ranked.length - this.headIndex);
  }

  private drainPendingGets(): void {
    while (!this.closed && this.pendingGets.length > 0 && this.size() > 0) {
      const resolve = this.pendingGets.shift() as RankedCandidateResolve;
      const candidate = this.takeImmediate() as WaterfallRankedCandidate;
      this.logState('waiter_woken', 'candidate=' + candidate.id + ' source=' + candidate.source);
      resolve(candidate);
    }
  }

  private logState(event: string, detail: string = ''): void {
    if (this.log === null) return;
    this.log('[DiscoveryFeedReserve] event=' + event +
      ' size=' + this.size().toString() +
      ' target=' + this.targetWatermark.toString() +
      ' batch=' + this.refillBatchSize.toString() +
      ' pending=' + this.pendingGets.length.toString() +
      ' running=' + (this.refillRunning ? 'true' : 'false') +
      (detail.length > 0 ? ' ' + detail : ''));
  }
}

/** FIFO display buffer. It never scores or sorts candidates. */
export class DiscoveryFeedTail {
  private readonly upstream: DiscoveryFeedReserve;
  private readonly lowWatermark: number;
  private readonly refillBatchSize: number;
  private readonly log: ((message: string) => void) | null;
  private readonly items: WaterfallRankedCandidate[] = [];
  private readonly pendingGets: RankedCandidateResolve[] = [];
  private refillRunning: boolean = false;
  private closed: boolean = false;
  private refillBatches: number = 0;
  private upstreamGets: number = 0;

  constructor(upstream: DiscoveryFeedReserve, options: DiscoveryFeedTailOptions = {}) {
    this.upstream = upstream;
    this.lowWatermark = positiveInteger(options.lowWatermark, 17);
    this.refillBatchSize = positiveInteger(options.refillBatchSize, 5);
    this.log = options.log ?? null;
    this.logState('constructed');
    this.ensureWatermark();
  }

  tryGet(): WaterfallRankedCandidate | null {
    if (this.closed) return null;
    const candidate = this.items.length > 0 ? this.items.shift() as WaterfallRankedCandidate : null;
    this.ensureWatermark();
    return candidate;
  }

  get(): Promise<WaterfallRankedCandidate> {
    const immediate = this.tryGet();
    if (immediate !== null) return Promise.resolve(immediate);
    return new Promise<WaterfallRankedCandidate>((resolve: RankedCandidateResolve): void => {
      this.pendingGets.push(resolve);
      this.logState('get_blocked');
      this.ensureWatermark();
    });
  }

  ensureWatermark(): void {
    if (this.closed || this.refillRunning || this.items.length >= this.lowWatermark) return;
    this.refillRunning = true;
    this.logState('refill_started');
    void this.runRefillLoop();
  }

  snapshot(): DiscoveryFeedTailSnapshot {
    return {
      size: this.items.length,
      lowWatermark: this.lowWatermark,
      refillBatchSize: this.refillBatchSize,
      pendingGets: this.pendingGets.length,
      refillRunning: this.refillRunning,
      refillBatches: this.refillBatches,
      upstreamGets: this.upstreamGets
    };
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.items.splice(0, this.items.length);
    this.pendingGets.splice(0, this.pendingGets.length);
    this.logState('closed');
  }

  private async runRefillLoop(): Promise<void> {
    let failed = false;
    try {
      while (!this.closed && this.items.length < this.lowWatermark) {
        const batch: WaterfallRankedCandidate[] = [];
        for (let index = 0; index < this.refillBatchSize && !this.closed; index++) {
          batch.push(await this.upstream.get());
          this.upstreamGets++;
        }
        if (batch.length > 0 && !this.closed) {
          batch.forEach((candidate: WaterfallRankedCandidate): void => {
            this.items.push(candidate);
          });
          this.refillBatches++;
          this.logState('batch_inserted', 'received=' + batch.length.toString());
          this.drainPendingGets();
        }
      }
    } catch (error) {
      failed = true;
      const message = error instanceof Error ? error.message : 'Unknown tail refill failure.';
      this.logState('refill_failed', message.substring(0, 200));
    } finally {
      this.refillRunning = false;
      this.logState('refill_stopped');
      if (!failed && !this.closed && this.items.length < this.lowWatermark) this.ensureWatermark();
    }
  }

  private drainPendingGets(): void {
    while (!this.closed && this.pendingGets.length > 0 && this.items.length > 0) {
      const resolve = this.pendingGets.shift() as RankedCandidateResolve;
      resolve(this.items.shift() as WaterfallRankedCandidate);
    }
  }

  private logState(event: string, detail: string = ''): void {
    if (this.log === null) return;
    this.log('[DiscoveryFeedTail] event=' + event +
      ' size=' + this.items.length.toString() +
      ' low=' + this.lowWatermark.toString() +
      ' batch=' + this.refillBatchSize.toString() +
      ' pending=' + this.pendingGets.length.toString() +
      ' running=' + (this.refillRunning ? 'true' : 'false') +
      (detail.length > 0 ? ' ' + detail : ''));
  }
}
