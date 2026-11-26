export type EventLimits = { events: number; bytes: number };
export type Replay = { seq: number; replay: "complete" | "gap"; texts: string[] };

export const DEFAULT_EVENT_LIMITS: EventLimits = { events: 20_000, bytes: 32 * 1024 * 1024 };

const COMPACT_AFTER = 1024;

export class EventLog {
  private entries: { seq: number; text: string }[] = [];
  private start = 0;
  private bytes = 0;
  private latest = 0;
  private readonly limits: EventLimits;

  constructor(limits: EventLimits) {
    this.limits = limits;
  }

  get seq(): number { return this.latest; }

  append(render: (seq: number) => string): string {
    const seq = ++this.latest;
    const text = render(seq);
    this.entries.push({ seq, text });
    this.bytes += text.length;
    while (this.start < this.entries.length && (this.entries.length - this.start > this.limits.events || this.bytes > this.limits.bytes)) {
      this.bytes -= this.entries[this.start]!.text.length;
      this.start += 1;
    }
    if (this.start > COMPACT_AFTER && this.start * 2 > this.entries.length) {
      this.entries = this.entries.slice(this.start);
      this.start = 0;
    }
    return text;
  }

  since(since: number): Replay {
    const first = this.entries[this.start]?.seq ?? this.latest + 1;
    const complete = since <= this.latest && since + 1 >= first;
    const from = this.start + Math.max(0, since + 1 - first);
    const texts = this.entries.slice(from).map((entry) => entry.text);
    return { seq: this.latest, replay: complete ? "complete" : "gap", texts };
  }

  clear(): void {
    this.entries = [];
    this.start = 0;
    this.bytes = 0;
  }
}
