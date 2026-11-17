// Appended to the existing ES module by the local desktop companion only.
// No backend files are changed. The adapter fails visibly on unsupported pages.
{
  const nativePost = (kind, value = '') => window.webkit?.messageHandlers?.discoboxDesktop?.postMessage({kind, value});
  let attached = null;
  const editing = () => {
    const el = document.activeElement;
    return el && (el.matches('input,textarea') || el.isContentEditable);
  };
  document.addEventListener('focusin', () => nativePost('editing', !!editing()));
  const current = () => {
    if (typeof state === 'undefined' || !state.rfb || !state.connected) throw new Error('Desktop is not connected yet.');
    return state.rfb;
  };
  window.discoboxNative = {
    command(key, terminal) {
      const rfb = current();
      const shifted = terminal && ['c', 'v'].includes(key);
      // macOS may already have delivered the Command modifier to the canvas.
      rfb.sendKey(0xffeb, 'MetaLeft', false); rfb.sendKey(0xffec, 'MetaRight', false);
      rfb.sendKey(0xffe3, 'ControlLeft', true);
      if (shifted) rfb.sendKey(0xffe1, 'ShiftLeft', true);
      try { rfb.sendKey(key.codePointAt(0), 'Key' + key.toUpperCase()); }
      finally {
        if (shifted) rfb.sendKey(0xffe1, 'ShiftLeft', false);
        rfb.sendKey(0xffe3, 'ControlLeft', false);
      }
    },
    paste(text, terminal) {
      const rfb = current();
      rfb.clipboardPasteFrom(text);
      this.command('v', terminal);
    }
  };
  setInterval(() => {
    if (typeof state === 'undefined') { nativePost('error', 'This desktop page does not support the native clipboard bridge. Open it in your browser instead.'); return; }
    if (state.rfb !== attached && state.rfb) {
      attached = state.rfb;
      const connection = attached;
      connection.addEventListener('clipboard', event => {
        if (connection === state.rfb && typeof event.detail?.text === 'string') nativePost('clipboard', event.detail.text);
      });
    }
    nativePost('ready', !!state.connected);
  }, 200);
}
