import {
  FeedChannelAdapter,
  FeedChannelAvailabilityHook,
  FeedChannelKind,
  FeedChannelPhase
} from './FeedChannelAdapter';
import { WaterfallCandidate } from './WaterfallAnythingCore';

export interface WeightedFeedChannelRegistrationSnapshot {
  id: string;
  platformId: string;
  kind: string;
  weight: number;
  debt: number;
  remaining: number;
  bucketSize: number;
  phase: FeedChannelPhase;
  blocked: boolean;
}

export interface WeightedFeedChannelPoolSnapshot {
  pointer: number;
  pendingGets: number;
  delivered: number;
  channels: WeightedFeedChannelRegistrationSnapshot[];
}

export interface WeightedFeedChannelPoolOptions {
  log?: (message: string) => void;
  onDelivered?: (channelId: string, kind: FeedChannelKind, candidate: WaterfallCandidate) => void;
}

interface WeightedFeedChannelEntry {
  adapter: FeedChannelAdapter;
  weight: number;
  debt: number;
  remaining: number;
  delivered: number;
  blocked: boolean;
}

type PendingFeedResolve = (candidate: WaterfallCandidate) => void;

function positiveWeight(weight: number): number {
  if (!Number.isFinite(weight)) return 1;
  return Math.max(1, Math.floor(weight));
}

/**
 * Weighted round-robin channel pool.
 *
 * An available channel emits weight items before the pointer advances. If the
 * current channel is empty, it accrues one debt and the pointer advances
 * immediately. On its next visit it receives weight + debt opportunities.
 */
export class WeightedFeedChannelPool implements FeedChannelAvailabilityHook {
  private readonly entries: WeightedFeedChannelEntry[] = [];
  private readonly pendingGets: PendingFeedResolve[] = [];
  private readonly seenIds: Set<string> = new Set<string>();
  private readonly seenUrls: Set<string> = new Set<string>();
  private readonly log: ((message: string) => void) | null;
  private readonly onDelivered: ((channelId: string, kind: FeedChannelKind,
    candidate: WaterfallCandidate) => void) | null;
  private pointer: number = 0;
  private delivered: number = 0;
  private draining: boolean = false;
  private closed: boolean = false;

  constructor(options: WeightedFeedChannelPoolOptions = {}) {
    this.log = options.log ?? null;
    this.onDelivered = options.onDelivered ?? null;
    this.logState('constructed');
  }

  register(adapter: FeedChannelAdapter, weight: number = 1): void {
    if (this.closed) throw new Error('WeightedFeedChannelPool is closed.');
    if (this.indexOf(adapter.id) >= 0) {
      throw new Error('Feed channel already registered: ' + adapter.id);
    }
    const normalizedWeight = positiveWeight(weight);
    this.entries.push({
      adapter,
      weight: normalizedWeight,
      debt: 0,
      remaining: normalizedWeight,
      delivered: 0,
      blocked: false
    });
    this.logState('registered', adapter.id);
    this.drainPendingGets();
  }

  tryGet(): WaterfallCandidate | null {
    this.logState('try_get_started');
    if (this.closed || this.entries.length === 0) return null;
    let checked = 0;
    while (checked < this.entries.length) {
      const entry = this.entries[this.pointer];
      if (entry.blocked) {
        this.logState('blocked_skipped', entry.adapter.id);
        this.advance();
        checked++;
        continue;
      }
      if (entry.remaining <= 0) entry.remaining = entry.weight + entry.debt;
      let candidate = entry.adapter.tryTake();
      while (candidate !== null && this.isDuplicate(candidate)) {
        this.logState('duplicate_dropped', entry.adapter.id);
        candidate = entry.adapter.tryTake();
      }
      if (candidate !== null) {
        this.remember(candidate);
        entry.remaining--;
        entry.delivered++;
        this.delivered++;
        if (entry.remaining <= 0) {
          entry.debt = 0;
          this.advance();
        }
        this.logState('get_returned', entry.adapter.id, candidate.source);
        if (this.onDelivered !== null) {
          try {
            this.onDelivered(entry.adapter.id, entry.adapter.kind, candidate);
          } catch (_error) {}
        }
        return candidate;
      }
      const phase = entry.adapter.snapshot().phase;
      if (phase === 'exhausted' || phase === 'error' || phase === 'closed') {
        entry.debt = 0;
        entry.remaining = 0;
        this.logState('terminal_skipped', entry.adapter.id);
        this.advance();
        checked++;
        continue;
      }
      entry.debt++;
      entry.adapter.ensureWatermark(entry.debt);
      entry.remaining = 0;
      this.logState('debt_accrued', entry.adapter.id);
      this.advance();
      checked++;
    }
    this.logState('all_empty');
    return null;
  }

  get(): Promise<WaterfallCandidate> {
    this.logState('get_requested');
    const immediate = this.tryGet();
    if (immediate !== null) return Promise.resolve(immediate);
    return new Promise<WaterfallCandidate>((resolve: PendingFeedResolve): void => {
      this.pendingGets.push(resolve);
      this.logState('get_blocked');
    });
  }

  onFeedChannelAvailable(channelId: string): void {
    if (this.closed || this.indexOf(channelId) < 0) return;
    this.logState('channel_available', channelId);
    this.drainPendingGets();
  }

  setPlatformBlocked(platformId: string, blocked: boolean): void {
    let changed = false;
    this.entries.forEach((entry: WeightedFeedChannelEntry): void => {
      if (entry.adapter.platformId !== platformId || entry.blocked === blocked) return;
      entry.blocked = blocked;
      entry.debt = 0;
      entry.remaining = entry.weight;
      entry.adapter.setBlocked(blocked);
      changed = true;
    });
    if (!changed) return;
    this.logState(blocked ? 'platform_blocked' : 'platform_unblocked', platformId);
    this.drainPendingGets();
  }

  snapshot(): WeightedFeedChannelPoolSnapshot {
    const channels: WeightedFeedChannelRegistrationSnapshot[] = this.entries.map(
      (entry: WeightedFeedChannelEntry): WeightedFeedChannelRegistrationSnapshot => {
        const snapshot = entry.adapter.snapshot();
        return {
          id: entry.adapter.id,
          platformId: entry.adapter.platformId,
          kind: entry.adapter.kind,
          weight: entry.weight,
          debt: entry.debt,
          remaining: entry.remaining,
          bucketSize: snapshot.size,
          phase: snapshot.phase,
          blocked: entry.blocked
        };
      }
    );
    return {
      pointer: this.pointer,
      pendingGets: this.pendingGets.length,
      delivered: this.delivered,
      channels
    };
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.entries.forEach((entry: WeightedFeedChannelEntry): void => entry.adapter.close());
    this.entries.splice(0, this.entries.length);
    this.pendingGets.splice(0, this.pendingGets.length);
    this.pointer = 0;
    this.logState('closed');
  }

  private drainPendingGets(): void {
    if (this.draining || this.closed) return;
    this.draining = true;
    try {
      while (this.pendingGets.length > 0) {
        const candidate = this.tryGet();
        if (candidate === null) return;
        const resolve = this.pendingGets.shift() as PendingFeedResolve;
        resolve(candidate);
      }
    } finally {
      this.draining = false;
    }
  }

  private indexOf(channelId: string): number {
    for (let index = 0; index < this.entries.length; index++) {
      if (this.entries[index].adapter.id === channelId) return index;
    }
    return -1;
  }

  private advance(): void {
    if (this.entries.length === 0) {
      this.pointer = 0;
      return;
    }
    this.pointer = (this.pointer + 1) % this.entries.length;
  }

  private isDuplicate(candidate: WaterfallCandidate): boolean {
    return (candidate.id.length > 0 && this.seenIds.has(candidate.id)) ||
      (candidate.url.length > 0 && this.seenUrls.has(candidate.url));
  }

  private remember(candidate: WaterfallCandidate): void {
    if (candidate.id.length > 0) this.seenIds.add(candidate.id);
    if (candidate.url.length > 0) this.seenUrls.add(candidate.url);
  }

  private logState(event: string, channelId: string = '', source: string = ''): void {
    if (this.log === null) return;
    const bucketText = this.entries.map((entry: WeightedFeedChannelEntry, index: number): string => {
      const snapshot = entry.adapter.snapshot();
      return (index === this.pointer ? '*' : '') + entry.adapter.id +
        '{size=' + snapshot.size.toString() +
        ',debt=' + entry.debt.toString() +
        ',remaining=' + entry.remaining.toString() +
        ',weight=' + entry.weight.toString() +
        ',blocked=' + (entry.blocked ? 'true' : 'false') +
        ',phase=' + snapshot.phase + '}';
    }).join(',');
    this.log('[WeightedFeedChannelPool] event=' + event +
      ' channel=' + channelId +
      ' source=' + source +
      ' pointer=' + this.pointer.toString() +
      ' pending=' + this.pendingGets.length.toString() +
      ' delivered=' + this.delivered.toString() +
      ' buckets=[' + bucketText + ']');
  }
}
