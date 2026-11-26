export function createReconnectController({
  connect,
  baseDelayMs = 2000,
  maxDelayMs = 30000,
  jitterMs = 1000,
  random = Math.random,
  scheduleTimer = setTimeout,
  cancelTimer = clearTimeout,
} = {}) {
  if (typeof connect !== "function") throw new TypeError("RECONNECT_CONNECT_REQUIRED");
  if (!Number.isFinite(baseDelayMs) || baseDelayMs < 1 ||
      !Number.isFinite(maxDelayMs) || maxDelayMs < baseDelayMs ||
      !Number.isFinite(jitterMs) || jitterMs < 0) {
    throw new TypeError("RECONNECT_DELAY_CONFIGURATION_INVALID");
  }
  if (typeof random !== "function" || typeof scheduleTimer !== "function" ||
      typeof cancelTimer !== "function") {
    throw new TypeError("RECONNECT_TIMER_CONFIGURATION_INVALID");
  }

  let timer = null;
  let nextDelayMs = baseDelayMs;
  let stopped = false;

  return Object.freeze({
    schedule() {
      if (stopped || timer !== null) return null;
      const sample = Number(random());
      const boundedSample = Number.isFinite(sample)
        ? Math.min(Math.max(sample, 0), 0.999999999)
        : 0;
      const waitMs = Math.min(nextDelayMs, maxDelayMs) + Math.floor(boundedSample * jitterMs);
      nextDelayMs = Math.min(nextDelayMs * 2, maxDelayMs);
      // Deliberately keep this timer referenced: it is the only live handle while
      // the WebSocket is disconnected, and must keep Node alive for reconnect.
      timer = scheduleTimer(() => {
        timer = null;
        if (!stopped) connect();
      }, waitMs);
      return waitMs;
    },

    markStable() {
      if (!stopped) nextDelayMs = baseDelayMs;
    },

    stop() {
      if (stopped) return;
      stopped = true;
      if (timer !== null) cancelTimer(timer);
      timer = null;
    },

    get pending() { return timer !== null; },
    get stopped() { return stopped; },
    get nextDelayMs() { return nextDelayMs; },
  });
}
