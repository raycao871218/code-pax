'use strict';
(() => {
  const post = (message) => window.webkit.messageHandlers.terminal.postMessage(message);
  const terminal = new Terminal({
    cols: 100, rows: 30, scrollback: 5000, fontSize: 14, cursorBlink: true,
    fontFamily: 'ui-monospace, Menlo, monospace',
    theme: { background: '#111827', foreground: '#e5e7eb', cursor: '#e5e7eb' }
  });
  const fit = new FitAddon.FitAddon();
  terminal.loadAddon(fit);
  terminal.open(document.getElementById('terminal'));
  let acceptingInput = false;
  let applying = false;
  let replaying = false;
  terminal.options.disableStdin = true;
  terminal.onData((data) => {
    // Terminal replies (for example device-status reports) generated during historical replay
    // must not be delivered as new keystrokes to a running CLI.
    if (acceptingInput && (!applying || !replaying)) post({ type: 'input', data });
  });
  terminal.onResize(({cols, rows}) => post({ type: 'resize', cols, rows }));
  let resizeTimer;
  new ResizeObserver(() => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => fit.fit(), 120);
  }).observe(document.getElementById('terminal'));
  window.cliTerminal = {
    write: (base64, reset, replay) => new Promise((resolve) => {
      applying = true;
      replaying = replay;
      if (reset) terminal.reset();
      const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
      terminal.write(bytes, () => { applying = false; resolve(true); });
    }),
    setInput: (enabled) => {
      acceptingInput = enabled;
      terminal.options.disableStdin = !enabled;
    },
    pasteAndSubmit: (text) => {
      if (!acceptingInput) return false;
      terminal.paste(text);
      post({ type: 'input', data: '\r' });
      return true;
    },
    key: (data) => {
      if (!acceptingInput) return;
      if (/^\x1b\[[ABCD]$/.test(data) && terminal.modes.applicationCursorKeysMode) {
        data = data.replace('[', 'O');
      }
      post({ type: 'input', data });
    },
    focus: () => terminal.focus()
  };
  fit.fit();
  post({ type: 'ready' });
})();
