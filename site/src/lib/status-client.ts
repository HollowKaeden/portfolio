interface Check {
  checked_at: number | null;
  available: boolean | null;
  duration_ms: number | null;
  history_ms: (number | null)[];
}

interface Snapshot {
  generated_at: number;
  projects: Record<string, Check>;
}

const refreshMs = 60_000;
const staleAfterSeconds = 180;
const dateFormat = new Intl.DateTimeFormat('ru-RU', { dateStyle: 'short', timeStyle: 'short' });

function fresh(timestamp: number | null | undefined) {
  return timestamp != null && Math.abs(Date.now() / 1000 - timestamp) <= staleAfterSeconds;
}

function drawHistory(row: HTMLElement, samples: Check['history_ms'], unit: string) {
  const chart = row.querySelector<HTMLElement>('.history')!;
  const data = samples.filter((sample): sample is number => sample !== null);
  chart.hidden = data.length === 0;
  if (chart.hidden) return;

  const maximum = Math.max(50, Math.ceil(Math.max(...data) / 50) * 50);
  let previous = false;
  const path = samples.map((sample, index) => {
    if (sample === null) {
      previous = false;
      return '';
    }
    const x = ((index + 0.5) * 480 / samples.length).toFixed(1);
    const y = (55 - sample * 54 / maximum).toFixed(1);
    const command = previous ? 'L' : 'M';
    previous = true;
    // The short horizontal segment keeps isolated samples visible.
    return `${command}${x} ${y}h0.01`;
  });
  row.querySelector('.series')!.setAttribute('d', path.join(' '));
  row.querySelector('.scale')!.textContent = `${maximum} ${unit}`;
}

class StatusOverview extends HTMLElement {
  private timer?: ReturnType<typeof setInterval>;
  private snapshot?: Snapshot;

  connectedCallback() {
    void this.refresh();
    this.timer = setInterval(() => void this.refresh(), refreshMs);
  }

  disconnectedCallback() {
    clearInterval(this.timer);
  }

  private async refresh() {
    try {
      const response = await fetch('/status/data.json', { signal: AbortSignal.timeout(5_000) });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      this.snapshot = await response.json();
    } catch {
      // The last successful snapshot can still describe the history after a temporary failure.
    }

    const snapshot = this.snapshot;
    const snapshotFresh = fresh(snapshot?.generated_at);
    this.querySelectorAll<HTMLElement>('[data-project]').forEach((row) => {
      const check = snapshot?.projects?.[row.dataset.project!];
      const state = snapshotFresh && fresh(check?.checked_at) && typeof check?.available === 'boolean'
        ? (check.available ? 'available' : 'unavailable')
        : 'unknown';
      row.dataset.state = state;
      row.querySelector('.state')!.textContent = this.dataset[state] ?? '';
      row.querySelector('.duration')!.textContent = state === 'available' && check?.duration_ms != null
        ? `${check.duration_ms} ${this.dataset.unit}`
        : '';
      drawHistory(row, snapshotFresh ? (check?.history_ms ?? []) : [], this.dataset.unit ?? '');
    });

    if (snapshot && Number.isFinite(snapshot.generated_at)) {
      const date = new Date(snapshot.generated_at * 1000);
      const label = this.querySelector<HTMLElement>('.updated')!;
      const time = label.querySelector('time')!;
      time.dateTime = date.toISOString();
      time.textContent = dateFormat.format(date);
      label.hidden = false;
    }
  }
}

customElements.define('status-overview', StatusOverview);
